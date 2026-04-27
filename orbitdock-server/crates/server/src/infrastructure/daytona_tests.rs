use super::{
  DaytonaConfig, DaytonaConfigSourceValues, DaytonaSandboxResponse, DaytonaSandboxState,
};

#[test]
fn daytona_config_prefers_env_over_persisted_values() {
  let config = DaytonaConfig::from_sources(
    DaytonaConfigSourceValues {
      api_url: Some("https://env.daytona.example".into()),
      api_key: Some("env-key".into()),
      public_url: Some("https://dock.example.com".into()),
      image: Some("custom-image".into()),
      target: Some("us".into()),
    },
    DaytonaConfigSourceValues {
      api_url: Some("https://persisted.daytona.example".into()),
      api_key: Some("persisted-key".into()),
      public_url: Some("https://persisted-dock.example.com".into()),
      image: Some("persisted-image".into()),
      target: Some("eu".into()),
    },
  )
  .expect("resolve config");

  assert_eq!(config.api_url, "https://env.daytona.example");
  assert_eq!(config.api_key, "env-key");
  assert_eq!(config.server_public_url, "https://dock.example.com");
  assert_eq!(config.image, "custom-image");
  assert_eq!(config.target.as_deref(), Some("us"));
}

#[test]
fn daytona_config_requires_minimum_runtime_values() {
  let error = DaytonaConfig::from_sources(
    DaytonaConfigSourceValues::default(),
    DaytonaConfigSourceValues::default(),
  )
  .expect_err("missing config should fail");

  assert!(error.to_string().contains("daytona_api_url"));
}

#[test]
fn sandbox_response_requires_toolbox_proxy_url() {
  let error = DaytonaSandboxResponse {
    id: "sandbox-1".into(),
    name: "orbitdock".into(),
    state: DaytonaSandboxState::Started,
    toolbox_proxy_url: String::new(),
  }
  .into_sandbox()
  .expect_err("missing toolbox url should fail");

  assert!(error.to_string().contains("toolboxProxyUrl"));
}
