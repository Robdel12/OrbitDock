use codex_app_server_protocol::{
  ConfigBatchWriteParams, ConfigEdit, ConfigReadParams, ConfigReadResponse, ConfigValueWriteParams,
  ConfigWriteResponse, OverriddenMetadata, WriteStatus,
};

use super::codex_config_types::{
  CodexConfigBatchWriteRequest, CodexConfigMergeStrategy, CodexConfigOverriddenMetadata,
  CodexConfigValueWriteRequest, CodexConfigWriteResponseData, CodexInspectorOrigin,
};

pub(crate) async fn read_codex_config(cwd: &str) -> Result<ConfigReadResponse, String> {
  let app_server = orbitdock_connector_codex::app_server::shared_app_server_for_cwd(cwd)
    .await
    .map_err(|error| error.to_string())?;
  app_server
    .config_read(ConfigReadParams {
      include_layers: true,
      cwd: Some(cwd.to_string()),
    })
    .await
    .map_err(|error| error.to_string())
}

pub async fn codex_config_write_value(
  request: CodexConfigValueWriteRequest,
) -> Result<CodexConfigWriteResponseData, String> {
  let app_server = orbitdock_connector_codex::app_server::shared_app_server_for_cwd(&request.cwd)
    .await
    .map_err(|error| error.to_string())?;
  let response: ConfigWriteResponse = app_server
    .config_value_write(ConfigValueWriteParams {
      key_path: request.key_path,
      value: request.value,
      merge_strategy: request
        .merge_strategy
        .unwrap_or(CodexConfigMergeStrategy::Replace)
        .into(),
      file_path: request.file_path,
      expected_version: request.expected_version,
    })
    .await
    .map_err(|error| error.to_string())?;

  Ok(write_response(response))
}

pub async fn codex_config_batch_write(
  request: CodexConfigBatchWriteRequest,
) -> Result<CodexConfigWriteResponseData, String> {
  let app_server = orbitdock_connector_codex::app_server::shared_app_server_for_cwd(&request.cwd)
    .await
    .map_err(|error| error.to_string())?;
  let response: ConfigWriteResponse = app_server
    .config_batch_write(ConfigBatchWriteParams {
      edits: request
        .edits
        .into_iter()
        .map(|edit| ConfigEdit {
          key_path: edit.key_path,
          value: edit.value,
          merge_strategy: edit
            .merge_strategy
            .unwrap_or(CodexConfigMergeStrategy::Replace)
            .into(),
        })
        .collect(),
      file_path: request.file_path,
      expected_version: request.expected_version,
      reload_user_config: true,
    })
    .await
    .map_err(|error| error.to_string())?;

  Ok(write_response(response))
}

pub(crate) fn write_response(response: ConfigWriteResponse) -> CodexConfigWriteResponseData {
  CodexConfigWriteResponseData {
    status: match response.status {
      WriteStatus::Ok => "ok".to_string(),
      WriteStatus::OkOverridden => "ok_overridden".to_string(),
    },
    version: response.version,
    file_path: response.file_path.as_path().display().to_string(),
    overridden_metadata: response
      .overridden_metadata
      .map(overridden_metadata_response),
  }
}

pub(crate) fn overridden_metadata_response(
  value: OverriddenMetadata,
) -> CodexConfigOverriddenMetadata {
  CodexConfigOverriddenMetadata {
    message: value.message,
    overriding_layer: CodexInspectorOrigin {
      source_kind: super::resolver::source_kind_name(&value.overriding_layer.name),
      path: super::resolver::source_path(&value.overriding_layer.name),
      version: value.overriding_layer.version,
    },
    effective_value: value.effective_value,
  }
}
