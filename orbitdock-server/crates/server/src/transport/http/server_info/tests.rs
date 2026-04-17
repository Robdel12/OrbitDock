use axum::{extract::Path, extract::State, Json};

use crate::transport::http::test_support::new_persist_test_state;

use super::{
  get_workspace_provider, get_workspace_provider_config_value, set_workspace_provider,
  set_workspace_provider_config_value, test_workspace_provider,
  SetWorkspaceProviderConfigValueRequest, SetWorkspaceProviderRequest,
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
