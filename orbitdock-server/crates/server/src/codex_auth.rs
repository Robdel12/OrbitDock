use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use codex_core::auth::AuthCredentialsStoreMode;
use codex_core::auth::AuthManager;
use codex_core::auth::AuthMode;
use codex_core::auth::CodexAuth;
use codex_core::auth::CLIENT_ID;
use codex_core::config::find_codex_home;
use codex_login::run_login_server;
use codex_login::ServerOptions as LoginServerOptions;
use codex_login::ShutdownHandle;
use orbitdock_protocol::CodexAccount;
use orbitdock_protocol::CodexAccountStatus;
use orbitdock_protocol::CodexAuthMode;
use orbitdock_protocol::CodexLoginCancelStatus;
use orbitdock_protocol::ServerMessage;
use tokio::sync::broadcast;
use tokio::sync::Mutex;
use tracing::warn;
use uuid::Uuid;

const LOGIN_CHATGPT_TIMEOUT: Duration = Duration::from_secs(10 * 60);

#[derive(Clone)]
struct ActiveLogin {
    login_id: String,
    shutdown_handle: ShutdownHandle,
}

enum ServiceState {
    Ready {
        auth_manager: Arc<AuthManager>,
        codex_home: PathBuf,
        credentials_store_mode: AuthCredentialsStoreMode,
    },
    Disabled {
        reason: String,
    },
}

pub struct CodexAuthService {
    state: ServiceState,
    list_tx: broadcast::Sender<ServerMessage>,
    active_login: Arc<Mutex<Option<ActiveLogin>>>,
}

impl CodexAuthService {
    pub fn new(list_tx: broadcast::Sender<ServerMessage>) -> Self {
        match find_codex_home() {
            Ok(codex_home) => {
                let credentials_store_mode = AuthCredentialsStoreMode::Auto;
                let auth_manager =
                    AuthManager::shared(codex_home.clone(), true, credentials_store_mode);
                Self {
                    state: ServiceState::Ready {
                        auth_manager,
                        codex_home,
                        credentials_store_mode,
                    },
                    list_tx,
                    active_login: Arc::new(Mutex::new(None)),
                }
            }
            Err(err) => Self {
                state: ServiceState::Disabled {
                    reason: format!("Failed to find codex home: {err}"),
                },
                list_tx,
                active_login: Arc::new(Mutex::new(None)),
            },
        }
    }

    pub async fn read_account(&self, refresh_token: bool) -> Result<CodexAccountStatus, String> {
        let auth_manager = self.auth_manager()?;

        // Pick up any auth changes made by CLI outside OrbitDock.
        auth_manager.reload();

        if refresh_token {
            if let Err(err) = auth_manager.refresh_token().await {
                warn!(
                    error = %err,
                    "Failed to refresh ChatGPT auth token while reading account state"
                );
            }
        }

        Ok(self.status_from_auth_manager(&auth_manager).await)
    }

    pub async fn start_chatgpt_login(&self) -> Result<(String, String), String> {
        let (auth_manager, codex_home, credentials_store_mode) = self.ready_parts()?;

        let opts = LoginServerOptions {
            open_browser: false,
            ..LoginServerOptions::new(
                codex_home.clone(),
                CLIENT_ID.to_string(),
                None,
                credentials_store_mode,
            )
        };

        let server =
            run_login_server(opts).map_err(|err| format!("failed to start login server: {err}"))?;
        let login_id = Uuid::new_v4().to_string();
        let auth_url = server.auth_url.clone();
        let shutdown_handle = server.cancel_handle();

        {
            let mut guard = self.active_login.lock().await;
            if let Some(existing) = guard.take() {
                existing.shutdown_handle.shutdown();
            }
            *guard = Some(ActiveLogin {
                login_id: login_id.clone(),
                shutdown_handle: shutdown_handle.clone(),
            });
        }

        let active_login = self.active_login.clone();
        let list_tx = self.list_tx.clone();
        let login_id_for_task = login_id.clone();
        tokio::spawn(async move {
            let (success, error) = match tokio::time::timeout(
                LOGIN_CHATGPT_TIMEOUT,
                server.block_until_done(),
            )
            .await
            {
                Ok(Ok(())) => (true, None),
                Ok(Err(err)) => (false, Some(format!("Login server error: {err}"))),
                Err(_) => {
                    shutdown_handle.shutdown();
                    (false, Some("Login timed out".to_string()))
                }
            };

            {
                let mut guard = active_login.lock().await;
                if guard.as_ref().map(|v| v.login_id.as_str()) == Some(login_id_for_task.as_str()) {
                    *guard = None;
                }
            }

            if success {
                auth_manager.reload();
            }

            let _ = list_tx.send(ServerMessage::CodexLoginChatgptCompleted {
                login_id: login_id_for_task.clone(),
                success,
                error,
            });

            let status = Self::status_from_parts(&auth_manager, &active_login).await;
            if success {
                let _ = list_tx.send(ServerMessage::CodexAccountUpdated {
                    status: status.clone(),
                });
            }
            let _ = list_tx.send(ServerMessage::CodexAccountStatus { status });
        });

        Ok((login_id, auth_url))
    }

    pub async fn cancel_chatgpt_login(&self, login_id: String) -> CodexLoginCancelStatus {
        if Uuid::parse_str(&login_id).is_err() {
            return CodexLoginCancelStatus::InvalidId;
        }

        let mut guard = self.active_login.lock().await;
        if guard.as_ref().map(|v| v.login_id.as_str()) == Some(login_id.as_str()) {
            if let Some(active) = guard.take() {
                active.shutdown_handle.shutdown();
            }
            CodexLoginCancelStatus::Canceled
        } else {
            CodexLoginCancelStatus::NotFound
        }
    }

    pub async fn logout(&self) -> Result<CodexAccountStatus, String> {
        let auth_manager = self.auth_manager()?;

        {
            let mut guard = self.active_login.lock().await;
            if let Some(active) = guard.take() {
                active.shutdown_handle.shutdown();
            }
        }

        auth_manager
            .logout()
            .map_err(|err| format!("logout failed: {err}"))?;

        Ok(self.status_from_auth_manager(&auth_manager).await)
    }

    fn auth_manager(&self) -> Result<Arc<AuthManager>, String> {
        match &self.state {
            ServiceState::Ready { auth_manager, .. } => Ok(auth_manager.clone()),
            ServiceState::Disabled { reason } => Err(reason.clone()),
        }
    }

    fn ready_parts(&self) -> Result<(Arc<AuthManager>, PathBuf, AuthCredentialsStoreMode), String> {
        match &self.state {
            ServiceState::Ready {
                auth_manager,
                codex_home,
                credentials_store_mode,
            } => Ok((
                auth_manager.clone(),
                codex_home.clone(),
                *credentials_store_mode,
            )),
            ServiceState::Disabled { reason } => Err(reason.clone()),
        }
    }

    async fn status_from_auth_manager(
        &self,
        auth_manager: &Arc<AuthManager>,
    ) -> CodexAccountStatus {
        Self::status_from_parts(auth_manager, &self.active_login).await
    }

    async fn status_from_parts(
        auth_manager: &Arc<AuthManager>,
        active_login: &Arc<Mutex<Option<ActiveLogin>>>,
    ) -> CodexAccountStatus {
        let auth = auth_manager.auth().await;
        let active_login_id = active_login
            .lock()
            .await
            .as_ref()
            .map(|v| v.login_id.clone());
        let account = auth.as_ref().map(Self::account_from_auth);
        CodexAccountStatus {
            auth_mode: auth.as_ref().map(Self::auth_mode_from_auth),
            requires_openai_auth: true,
            account,
            login_in_progress: active_login_id.is_some(),
            active_login_id,
        }
    }

    fn auth_mode_from_auth(auth: &CodexAuth) -> CodexAuthMode {
        match auth.auth_mode() {
            AuthMode::ApiKey => CodexAuthMode::ApiKey,
            AuthMode::Chatgpt => CodexAuthMode::Chatgpt,
        }
    }

    fn account_from_auth(auth: &CodexAuth) -> CodexAccount {
        match auth.auth_mode() {
            AuthMode::ApiKey => CodexAccount::ApiKey,
            AuthMode::Chatgpt => CodexAccount::Chatgpt {
                email: auth.get_account_email(),
                plan_type: auth
                    .account_plan_type()
                    .map(|value| format!("{value:?}").to_lowercase()),
            },
        }
    }
}
