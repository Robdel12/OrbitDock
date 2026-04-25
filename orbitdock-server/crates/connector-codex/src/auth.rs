use std::path::PathBuf;
use std::sync::Arc;

use codex_app_server_protocol::{
  Account, CancelLoginAccountStatus, GetAccountResponse, LoginAccountParams, LoginAccountResponse,
  ServerNotification,
};
use orbitdock_protocol::CodexAccount;
use orbitdock_protocol::CodexAccountStatus;
use orbitdock_protocol::CodexAuthMode;
use orbitdock_protocol::CodexLoginCancelStatus;
use orbitdock_protocol::ServerMessage;
use tokio::sync::broadcast;
use tokio::sync::Mutex;

pub struct CodexAuthService {
  auth_home: PathBuf,
  list_tx: broadcast::Sender<ServerMessage>,
  active_login_id: Arc<Mutex<Option<String>>>,
}

impl CodexAuthService {
  pub fn new(list_tx: broadcast::Sender<ServerMessage>) -> Self {
    Self::new_with_auth_home(list_tx, default_auth_cwd())
  }

  pub fn new_with_file_store(
    list_tx: broadcast::Sender<ServerMessage>,
    codex_home: PathBuf,
  ) -> Self {
    Self::new_with_auth_home(list_tx, codex_home)
  }

  fn new_with_auth_home(list_tx: broadcast::Sender<ServerMessage>, auth_home: PathBuf) -> Self {
    Self {
      auth_home,
      list_tx,
      active_login_id: Arc::new(Mutex::new(None)),
    }
  }

  pub async fn read_account(&self, refresh_token: bool) -> Result<CodexAccountStatus, String> {
    let app_server = self.app_server().await?;
    let response = app_server
      .account_read(refresh_token)
      .await
      .map_err(|error| error.to_string())?;
    Ok(self.status_from_response(response).await)
  }

  pub async fn start_chatgpt_login(&self) -> Result<(String, String), String> {
    let app_server = self.app_server().await?;
    let notifications = app_server.subscribe_global_notifications();
    let response = app_server
      .account_login_start(LoginAccountParams::Chatgpt)
      .await
      .map_err(|error| error.to_string())?;

    let LoginAccountResponse::Chatgpt { login_id, auth_url } = response else {
      return Err("Codex app-server returned a non-ChatGPT login response".to_string());
    };

    *self.active_login_id.lock().await = Some(login_id.clone());
    self.spawn_login_completion_watcher(Arc::clone(&app_server), login_id.clone(), notifications);
    Ok((login_id, auth_url))
  }

  pub async fn cancel_chatgpt_login(&self, login_id: String) -> CodexLoginCancelStatus {
    let Ok(app_server) = self.app_server().await else {
      return CodexLoginCancelStatus::NotFound;
    };
    let response = app_server.account_login_cancel(login_id.clone()).await;
    let status = match response {
      Ok(response) => match response.status {
        CancelLoginAccountStatus::Canceled => CodexLoginCancelStatus::Canceled,
        CancelLoginAccountStatus::NotFound => CodexLoginCancelStatus::NotFound,
      },
      Err(_) => CodexLoginCancelStatus::NotFound,
    };

    if matches!(status, CodexLoginCancelStatus::Canceled) {
      let mut active = self.active_login_id.lock().await;
      if active.as_deref() == Some(login_id.as_str()) {
        *active = None;
      }
    }

    status
  }

  pub async fn logout(&self) -> Result<CodexAccountStatus, String> {
    let app_server = self.app_server().await?;
    app_server
      .account_logout()
      .await
      .map_err(|error| error.to_string())?;
    *self.active_login_id.lock().await = None;
    self.read_account(false).await
  }

  async fn app_server(&self) -> Result<Arc<crate::app_server::CodexAppServer>, String> {
    let cwd = self.auth_home.to_string_lossy();
    crate::app_server::shared_app_server_for_cwd(&cwd)
      .await
      .map_err(|error| error.to_string())
  }

  fn spawn_login_completion_watcher(
    &self,
    app_server: Arc<crate::app_server::CodexAppServer>,
    login_id: String,
    mut notifications: broadcast::Receiver<ServerNotification>,
  ) {
    let active_login_id = self.active_login_id.clone();
    let list_tx = self.list_tx.clone();
    tokio::spawn(async move {
      loop {
        let notification = match notifications.recv().await {
          Ok(notification) => notification,
          Err(broadcast::error::RecvError::Lagged(_)) => continue,
          Err(broadcast::error::RecvError::Closed) => return,
        };

        let ServerNotification::AccountLoginCompleted(event) = notification else {
          continue;
        };
        if event.login_id.as_deref() != Some(login_id.as_str()) {
          continue;
        }

        {
          let mut active = active_login_id.lock().await;
          if active.as_deref() == Some(login_id.as_str()) {
            *active = None;
          }
        }

        let _ = list_tx.send(ServerMessage::CodexLoginChatgptCompleted {
          login_id: login_id.clone(),
          success: event.success,
          error: event.error,
        });

        if let Ok(response) = app_server.account_read(false).await {
          let status = status_from_response(response, &active_login_id).await;
          if event.success {
            let _ = list_tx.send(ServerMessage::CodexAccountUpdated {
              status: status.clone(),
            });
          }
          let _ = list_tx.send(ServerMessage::CodexAccountStatus { status });
        }
        return;
      }
    });
  }

  async fn status_from_response(&self, response: GetAccountResponse) -> CodexAccountStatus {
    status_from_response(response, &self.active_login_id).await
  }
}

fn default_auth_cwd() -> PathBuf {
  dirs::home_dir().unwrap_or_else(|| PathBuf::from("."))
}

fn auth_mode_from_account(account: &Account) -> CodexAuthMode {
  match account {
    Account::ApiKey {} | Account::AmazonBedrock {} => CodexAuthMode::ApiKey,
    Account::Chatgpt { .. } => CodexAuthMode::Chatgpt,
  }
}

fn account_from_app_server(account: Account) -> CodexAccount {
  match account {
    Account::ApiKey {} | Account::AmazonBedrock {} => CodexAccount::ApiKey,
    Account::Chatgpt { email, plan_type } => CodexAccount::Chatgpt {
      email: Some(email),
      plan_type: Some(format!("{plan_type:?}").to_lowercase()),
    },
  }
}

async fn status_from_response(
  response: GetAccountResponse,
  active_login_id: &Arc<Mutex<Option<String>>>,
) -> CodexAccountStatus {
  let active_login_id = active_login_id.lock().await.clone();
  CodexAccountStatus {
    auth_mode: response.account.as_ref().map(auth_mode_from_account),
    requires_openai_auth: response.requires_openai_auth,
    account: response.account.map(account_from_app_server),
    login_in_progress: active_login_id.is_some(),
    active_login_id,
  }
}

#[cfg(test)]
mod tests {
  use super::*;

  #[test]
  fn new_service_defers_app_server_start_until_used() {
    let (list_tx, _) = broadcast::channel(1);
    let service = CodexAuthService::new_with_auth_home(
      list_tx,
      PathBuf::from("/tmp/orbitdock-codex-auth-tests"),
    );

    assert_eq!(
      service.auth_home,
      PathBuf::from("/tmp/orbitdock-codex-auth-tests")
    );
  }

  #[test]
  fn new_with_file_store_uses_supplied_cwd_for_app_server_bootstrap() {
    let (list_tx, _) = broadcast::channel(1);
    let service =
      CodexAuthService::new_with_file_store(list_tx, PathBuf::from("/tmp/orbitdock-codex-tests"));

    assert_eq!(
      service.auth_home,
      PathBuf::from("/tmp/orbitdock-codex-tests")
    );
  }
}
