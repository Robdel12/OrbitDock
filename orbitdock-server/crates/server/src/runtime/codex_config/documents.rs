use codex_app_server_protocol::{ConfigLayer, ConfigLayerSource, ConfigReadResponse};
use serde_json::{Map, Value};

use super::codex_config_types::{
  CodexConfigDocument, CodexConfigDocumentScope, CodexConfigDocumentsResponse,
  CodexConfigProfileDocument, CodexProviderDocument,
};
use super::resolver::source_path;
use super::rpc_client::read_codex_config;

pub async fn codex_config_documents(cwd: &str) -> Result<CodexConfigDocumentsResponse, String> {
  let config_response = read_codex_config(cwd).await?;
  let user = user_document(&config_response);
  let projects = project_documents(&config_response);

  Ok(CodexConfigDocumentsResponse {
    cwd: Some(cwd.to_string()),
    user,
    projects,
    warnings: Vec::new(),
  })
}

fn user_document(config_response: &ConfigReadResponse) -> CodexConfigDocument {
  let Some(layer) = config_response.layers.as_ref().and_then(|layers| {
    layers
      .iter()
      .find(|layer| matches!(layer.name, ConfigLayerSource::User { .. }))
  }) else {
    return CodexConfigDocument {
      scope: CodexConfigDocumentScope::User,
      exists: false,
      writable: true,
      write_warning: None,
      file_path: default_user_config_path(),
      version: None,
      config: Value::Object(Map::new()),
      profiles: Vec::new(),
      providers: Vec::new(),
    };
  };

  config_document_from_layer(layer, CodexConfigDocumentScope::User, true, None)
}

fn project_documents(config_response: &ConfigReadResponse) -> Vec<CodexConfigDocument> {
  let mut documents: Vec<_> = config_response
    .layers
    .as_ref()
    .into_iter()
    .flat_map(|layers| layers.iter())
    .filter(|layer| matches!(layer.name, ConfigLayerSource::Project { .. }))
    .map(|layer| {
      config_document_from_layer(
        layer,
        CodexConfigDocumentScope::Project,
        false,
        Some("Codex currently only supports writes to the user config layer.".to_string()),
      )
    })
    .collect();
  documents.sort_by(|a, b| a.file_path.cmp(&b.file_path));
  documents
}

fn config_document_from_layer(
  layer: &ConfigLayer,
  scope: CodexConfigDocumentScope,
  writable: bool,
  write_warning: Option<String>,
) -> CodexConfigDocument {
  CodexConfigDocument {
    scope,
    exists: true,
    writable,
    write_warning,
    file_path: source_path(&layer.name),
    version: Some(layer.version.clone()),
    config: layer.config.clone(),
    profiles: config_profile_documents(&layer.config),
    providers: config_provider_documents(&layer.config),
  }
}

fn config_profile_documents(config: &Value) -> Vec<CodexConfigProfileDocument> {
  let mut profiles: Vec<_> = config
    .get("profiles")
    .and_then(Value::as_object)
    .into_iter()
    .flat_map(|profiles| profiles.iter())
    .map(|(name, profile)| CodexConfigProfileDocument {
      name: name.clone(),
      config: profile.clone(),
      model: profile
        .get("model")
        .and_then(Value::as_str)
        .map(str::to_string),
      model_provider: profile
        .get("model_provider")
        .and_then(Value::as_str)
        .map(str::to_string),
    })
    .collect();
  profiles.sort_by(|a, b| a.name.cmp(&b.name));
  profiles
}

fn config_provider_documents(config: &Value) -> Vec<CodexProviderDocument> {
  let mut providers: Vec<_> = config
    .get("model_providers")
    .and_then(Value::as_object)
    .into_iter()
    .flat_map(|providers| providers.iter())
    .map(|(id, provider)| CodexProviderDocument {
      id: id.clone(),
      config: provider.clone(),
      display_name: Some(id.clone()),
      base_url: provider
        .get("base_url")
        .and_then(Value::as_str)
        .map(str::to_string),
      wire_api: provider
        .get("wire_api")
        .and_then(Value::as_str)
        .map(str::to_string),
      env_key: provider
        .get("env_key")
        .and_then(Value::as_str)
        .map(str::to_string),
      is_custom: Some(true),
    })
    .collect();
  providers.sort_by(|a, b| a.id.cmp(&b.id));
  providers
}

fn default_user_config_path() -> Option<String> {
  std::env::var_os("HOME").map(|home| {
    std::path::PathBuf::from(home)
      .join(".codex")
      .join("config.toml")
      .display()
      .to_string()
  })
}
