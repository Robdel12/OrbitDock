use axum::{extract::Path, extract::State, Json};

use crate::runtime::session_registry::CachedUpdateStatus;
use crate::transport::http::test_support::new_persist_test_state;

use super::{
  get_server_meta, get_workspace_provider, get_workspace_provider_config_value,
  set_client_primary_claim, set_server_role, set_workspace_provider,
  set_workspace_provider_config_value, test_workspace_provider, SetClientPrimaryClaimRequest,
  SetServerRoleRequest, SetWorkspaceProviderConfigValueRequest, SetWorkspaceProviderRequest,
};

struct EnvVarGuard {
  key: &'static str,
  original: Option<String>,
}

impl EnvVarGuard {
  fn set(key: &'static str, value: &str) -> Self {
    let original = std::env::var(key).ok();
    unsafe {
      std::env::set_var(key, value);
    }
    Self { key, original }
  }
}

impl Drop for EnvVarGuard {
  fn drop(&mut self) {
    match &self.original {
      Some(value) => unsafe {
        std::env::set_var(self.key, value);
      },
      None => unsafe {
        std::env::remove_var(self.key);
      },
    }
  }
}

#[tokio::test]
async fn workspace_provider_endpoint_returns_authoritative_state_and_enqueues_config_write() {
  let (state, mut persist_rx, _db_path, _guard) = new_persist_test_state(true).await;

  let Json(updated) = set_workspace_provider(
    State(state.clone()),
    Json(SetWorkspaceProviderRequest {
      workspace_provider: orbitdock_protocol::WorkspaceProviderKind::Local,
    }),
  )
  .await
  .expect("set workspace provider should succeed");

  assert_eq!(
    updated.workspace_provider,
    orbitdock_protocol::WorkspaceProviderKind::Local
  );
  assert_eq!(
    state.workspace_provider_kind(),
    orbitdock_protocol::WorkspaceProviderKind::Local
  );

  let command = persist_rx
    .recv()
    .await
    .expect("workspace provider update should enqueue persistence");
  assert!(matches!(
      command,
      crate::infrastructure::persistence::PersistCommand::SetConfig { ref key, ref value }
          if key == "workspace_provider" && value == "local"
  ));

  let Json(reloaded) = get_workspace_provider(State(state)).await;
  assert_eq!(
    reloaded.workspace_provider,
    orbitdock_protocol::WorkspaceProviderKind::Local
  );
}

#[tokio::test]
async fn workspace_provider_config_endpoint_redacts_secret_values() {
  let (state, mut persist_rx, _db_path, _guard) = new_persist_test_state(true).await;

  let Json(updated) = set_workspace_provider_config_value(
    State(state),
    Path("daytona-api-key".to_string()),
    Json(SetWorkspaceProviderConfigValueRequest {
      value: "secret-token".to_string(),
    }),
  )
  .await
  .expect("set workspace provider config should succeed");

  assert_eq!(updated.key, "daytona-api-key");
  assert!(updated.configured);
  assert!(updated.secret);
  assert_eq!(updated.value, None);
  assert_eq!(updated.source.as_deref(), Some("settings"));

  let command = persist_rx
    .recv()
    .await
    .expect("workspace provider config update should enqueue persistence");
  assert!(matches!(
    command,
    crate::infrastructure::persistence::PersistCommand::SetConfig { ref key, ref value }
      if key == "daytona_api_key" && value == "secret-token"
  ));
}

#[tokio::test]
async fn workspace_provider_test_reports_local_provider_ready() {
  let (state, _persist_rx, _db_path, _guard) = new_persist_test_state(true).await;

  let Json(response) = test_workspace_provider(State(state))
    .await
    .expect("provider test should succeed");

  assert!(response.ok);
  assert_eq!(response.provider, "local");
  assert!(response.message.contains("ready"));
}

#[tokio::test]
async fn workspace_provider_config_endpoint_reports_env_override_as_effective_source() {
  let _env_guard = EnvVarGuard::set("ORBITDOCK_DAYTONA_API_URL", "https://env.daytona.example");
  let (state, mut persist_rx, _db_path, _guard) = new_persist_test_state(true).await;

  let Json(updated) = set_workspace_provider_config_value(
    State(state),
    Path("daytona-api-url".to_string()),
    Json(SetWorkspaceProviderConfigValueRequest {
      value: "https://settings.daytona.example".to_string(),
    }),
  )
  .await
  .expect("set workspace provider config should succeed");

  assert_eq!(updated.key, "daytona-api-url");
  assert_eq!(
    updated.value.as_deref(),
    Some("https://env.daytona.example")
  );
  assert!(updated.configured);
  assert_eq!(updated.source.as_deref(), Some("env"));

  let command = persist_rx
    .recv()
    .await
    .expect("workspace provider config update should enqueue persistence");
  assert!(matches!(
    command,
    crate::infrastructure::persistence::PersistCommand::SetConfig { ref key, ref value }
      if key == "daytona_api_url" && value == "https://settings.daytona.example"
  ));

  let Json(reloaded) = get_workspace_provider_config_value(Path("daytona-api-url".to_string()))
    .await
    .expect("get workspace provider config should succeed");
  assert_eq!(
    reloaded.value.as_deref(),
    Some("https://env.daytona.example")
  );
  assert_eq!(reloaded.source.as_deref(), Some("env"));
}

#[tokio::test]
async fn workspace_provider_config_endpoint_treats_blank_values_as_clear() {
  let (state, mut persist_rx, _db_path, _guard) = new_persist_test_state(true).await;

  let Json(updated) = set_workspace_provider_config_value(
    State(state),
    Path("daytona-target".to_string()),
    Json(SetWorkspaceProviderConfigValueRequest {
      value: "   ".to_string(),
    }),
  )
  .await
  .expect("clear workspace provider config should succeed");

  assert_eq!(updated.key, "daytona-target");
  assert!(!updated.configured);
  assert_eq!(updated.value, None);
  assert_eq!(updated.source, None);

  let command = persist_rx
    .recv()
    .await
    .expect("workspace provider config clear should enqueue persistence");
  assert!(matches!(
    command,
    crate::infrastructure::persistence::PersistCommand::SetConfig { ref key, ref value }
      if key == "daytona_target" && value.is_empty()
  ));
}

#[tokio::test]
async fn server_meta_endpoint_reflects_runtime_state() {
  let (state, _persist_rx, _db_path, _guard) = new_persist_test_state(true).await;
  state.set_primary(false);
  state.set_server_instance_id("server-123".to_string());
  state.set_client_primary_claim(7, "client-a".to_string(), "MacBook Pro".to_string(), true);
  state.set_update_status(CachedUpdateStatus {
    update_available: true,
    latest_version: Some("v9.9.9".to_string()),
    release_url: Some("https://example.test/releases/v9.9.9".to_string()),
    channel: "beta".to_string(),
    checked_at: chrono::Utc::now(),
  });

  let Json(meta) = get_server_meta(State(state)).await;

  assert_eq!(meta.server_version, crate::VERSION);
  assert_eq!(meta.minimum_client_version, crate::MINIMUM_CLIENT_VERSION);
  assert_eq!(meta.server_instance_id.as_deref(), Some("server-123"));
  assert!(!meta.is_primary);
  assert_eq!(meta.client_primary_claims.len(), 1);
  assert_eq!(
    meta.client_primary_claims[0],
    orbitdock_protocol::ClientPrimaryClaim {
      client_id: "client-a".to_string(),
      device_name: "MacBook Pro".to_string(),
    }
  );
  assert_eq!(
    meta
      .update_status
      .as_ref()
      .map(|status| status.channel.as_str()),
    Some("beta")
  );
  assert_eq!(
    meta
      .update_status
      .as_ref()
      .and_then(|status| status.latest_version.as_deref()),
    Some("v9.9.9")
  );
  assert!(meta
    .capabilities
    .contains(&orbitdock_protocol::CAPABILITY_SESSION_DETAIL_SURFACE_V1.to_string()));
  assert_eq!(meta.capabilities.len(), 5);
}

#[tokio::test]
async fn server_role_endpoint_updates_primary_state_and_persists_config() {
  let (state, mut persist_rx, _db_path, _guard) = new_persist_test_state(true).await;

  let Json(response) = set_server_role(
    State(state.clone()),
    Json(SetServerRoleRequest { is_primary: false }),
  )
  .await
  .expect("set server role should succeed");

  assert!(!response.is_primary);
  assert!(!state.is_primary());

  let command = persist_rx
    .recv()
    .await
    .expect("server role update should enqueue persistence");
  assert!(matches!(
    command,
    crate::infrastructure::persistence::PersistCommand::SetConfig { ref key, ref value }
      if key == "server_role" && value == "secondary"
  ));
}

#[tokio::test]
async fn client_primary_claim_endpoint_registers_claim() {
  let (state, _persist_rx, _db_path, _guard) = new_persist_test_state(true).await;

  let Json(response) = set_client_primary_claim(
    State(state.clone()),
    Json(SetClientPrimaryClaimRequest {
      client_id: "client-b".to_string(),
      device_name: "Mac Studio".to_string(),
      is_primary: true,
    }),
  )
  .await;

  assert!(response.accepted);
  assert_eq!(
    state.active_client_primary_claims(),
    vec![orbitdock_protocol::ClientPrimaryClaim {
      client_id: "client-b".to_string(),
      device_name: "Mac Studio".to_string(),
    }]
  );
}
