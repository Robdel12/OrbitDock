use codex_app_server_protocol::Config;

use super::codex_config_types::{
  CodexConfigCatalogResponse, CodexConfigProfileSummary, CodexConfigSelection, CodexProviderSummary,
};
use super::resolver::{
  normalized_optional_cwd, resolve_codex_settings, resolved_codex_context_cwd,
};
use super::rpc_client::read_codex_config;
use orbitdock_protocol::CodexConfigMode;
use orbitdock_protocol::CodexConfigSource;
use orbitdock_protocol::CodexSessionOverrides;

pub async fn codex_config_catalog(cwd: Option<&str>) -> Result<CodexConfigCatalogResponse, String> {
  let explicit_cwd = cwd.and_then(normalized_optional_cwd);
  let resolved_cwd = resolved_codex_context_cwd(explicit_cwd)?;
  let config_response = read_codex_config(&resolved_cwd).await?;

  let effective_settings = if let Some(explicit_cwd) = explicit_cwd {
    let selection = CodexConfigSelection {
      config_source: CodexConfigSource::User,
      config_mode: CodexConfigMode::Inherit,
      config_profile: None,
      model_provider: None,
      overrides: CodexSessionOverrides::default(),
    };
    Some(
      resolve_codex_settings(explicit_cwd, selection)
        .await?
        .effective_settings,
    )
  } else {
    None
  };

  Ok(CodexConfigCatalogResponse {
    cwd: explicit_cwd.map(str::to_string),
    effective_settings,
    profiles: config_profiles(&config_response.config),
    providers: config_providers(&config_response.config),
    warnings: Vec::new(),
  })
}

fn config_profiles(config: &Config) -> Vec<CodexConfigProfileSummary> {
  let mut profiles: Vec<_> = config
    .profiles
    .iter()
    .map(|(name, profile)| CodexConfigProfileSummary {
      name: name.clone(),
      model: profile.model.clone(),
      model_provider: profile.model_provider.clone(),
      source: Some("codex".to_string()),
    })
    .collect();
  profiles.sort_by(|a, b| a.name.cmp(&b.name));
  profiles
}

fn config_providers(config: &Config) -> Vec<CodexProviderSummary> {
  let mut providers: std::collections::HashMap<String, CodexProviderSummary> =
    built_in_provider_summaries()
      .into_iter()
      .map(|provider| (provider.id.clone(), provider))
      .collect();

  if let Some(custom) = config
    .additional
    .get("model_providers")
    .and_then(serde_json::Value::as_object)
  {
    for (id, raw) in custom {
      let raw = raw.as_object();
      providers.insert(
        id.clone(),
        CodexProviderSummary {
          id: id.clone(),
          display_name: Some(id.clone()),
          base_url: raw
            .and_then(|value| value.get("base_url"))
            .and_then(serde_json::Value::as_str)
            .map(str::to_string),
          wire_api: raw
            .and_then(|value| value.get("wire_api"))
            .and_then(serde_json::Value::as_str)
            .map(str::to_string),
          env_key: raw
            .and_then(|value| value.get("env_key"))
            .and_then(serde_json::Value::as_str)
            .map(str::to_string),
          is_custom: Some(true),
        },
      );
    }
  }

  let mut values: Vec<_> = providers.into_values().collect();
  values.sort_by(|a, b| a.id.cmp(&b.id));
  values
}

fn built_in_provider_summaries() -> Vec<CodexProviderSummary> {
  vec![
    CodexProviderSummary {
      id: "openai".to_string(),
      display_name: Some("OpenAI".to_string()),
      base_url: Some("https://api.openai.com/v1".to_string()),
      wire_api: Some("responses".to_string()),
      env_key: Some("OPENAI_API_KEY".to_string()),
      is_custom: Some(false),
    },
    CodexProviderSummary {
      id: "ollama".to_string(),
      display_name: Some("Ollama".to_string()),
      base_url: Some("http://localhost:11434/v1".to_string()),
      wire_api: Some("chat_completions".to_string()),
      env_key: None,
      is_custom: Some(false),
    },
    CodexProviderSummary {
      id: "lmstudio".to_string(),
      display_name: Some("LM Studio".to_string()),
      base_url: Some("http://localhost:1234/v1".to_string()),
      wire_api: Some("chat_completions".to_string()),
      env_key: None,
      is_custom: Some(false),
    },
  ]
}
