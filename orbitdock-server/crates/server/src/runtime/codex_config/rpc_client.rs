use std::process::Stdio;
use std::time::Duration;

use codex_app_server_protocol::{
  ConfigBatchWriteParams, ConfigEdit, ConfigReadParams, ConfigReadResponse, ConfigValueWriteParams,
  ConfigWriteResponse, OverriddenMetadata, WriteStatus,
};
use serde::Serialize;
use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{ChildStdout, Command};

use super::binary_discovery::{find_codex_binary, resolved_path_env_for_binary};
use super::codex_config_types::{
  CodexConfigBatchWriteRequest, CodexConfigMergeStrategy, CodexConfigOverriddenMetadata,
  CodexConfigValueWriteRequest, CodexConfigWriteResponseData, CodexInspectorOrigin,
};

pub(crate) async fn read_codex_config(cwd: &str) -> Result<ConfigReadResponse, String> {
  call_codex_app_server(
    cwd,
    2,
    "config/read",
    ConfigReadParams {
      include_layers: true,
      cwd: Some(cwd.to_string()),
    },
  )
  .await
}

pub async fn codex_config_write_value(
  request: CodexConfigValueWriteRequest,
) -> Result<CodexConfigWriteResponseData, String> {
  let response: ConfigWriteResponse = call_codex_app_server(
    &request.cwd,
    2,
    "config/value/write",
    ConfigValueWriteParams {
      key_path: request.key_path,
      value: request.value,
      merge_strategy: request
        .merge_strategy
        .unwrap_or(CodexConfigMergeStrategy::Replace)
        .into(),
      file_path: request.file_path,
      expected_version: request.expected_version,
    },
  )
  .await?;

  Ok(write_response(response))
}

pub async fn codex_config_batch_write(
  request: CodexConfigBatchWriteRequest,
) -> Result<CodexConfigWriteResponseData, String> {
  let response: ConfigWriteResponse = call_codex_app_server(
    &request.cwd,
    2,
    "config/batchWrite",
    ConfigBatchWriteParams {
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
    },
  )
  .await?;

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

pub(crate) fn json_rpc_error_message(method: &str, error: &Value) -> String {
  let message = error
    .get("message")
    .and_then(Value::as_str)
    .unwrap_or("Unknown JSON-RPC error");
  format!("{method} failed: {message}")
}

async fn call_codex_app_server<TParams, TResponse>(
  cwd: &str,
  request_id: i64,
  method: &str,
  params: TParams,
) -> Result<TResponse, String>
where
  TParams: Serialize,
  TResponse: serde::de::DeserializeOwned,
{
  let codex_path = find_codex_binary().ok_or_else(|| "Codex CLI not installed".to_string())?;
  let path_env = resolved_path_env_for_binary(&codex_path);

  let mut command = Command::new(&codex_path);
  command.arg("app-server");
  command.stdin(Stdio::piped());
  command.stdout(Stdio::piped());
  command.stderr(Stdio::piped());
  command.current_dir(cwd);
  if let Some(path_env) = path_env {
    command.env("PATH", path_env);
  }

  let mut child = command
    .spawn()
    .map_err(|error| format!("Failed to start codex app-server: {error}"))?;

  let Some(mut stdin) = child.stdin.take() else {
    let _ = child.kill().await;
    return Err("Failed to open codex app-server stdin".to_string());
  };
  let Some(stdout) = child.stdout.take() else {
    let _ = child.kill().await;
    return Err("Failed to open codex app-server stdout".to_string());
  };
  let mut lines = BufReader::new(stdout).lines();

  let result = async {
    send_json_rpc(
      &mut stdin,
      serde_json::json!({
        "method": "initialize",
        "id": 1,
        "params": {
          "clientInfo": {
            "name": "orbitdock",
            "title": "OrbitDock",
            "version": env!("CARGO_PKG_VERSION"),
          }
        }
      }),
    )
    .await?;
    let init_response = read_json_rpc_response(&mut lines, 1).await?;
    if let Some(error) = init_response.get("error") {
      return Err(json_rpc_error_message("initialize", error));
    }

    send_json_rpc(
      &mut stdin,
      serde_json::json!({
        "method": "initialized",
        "params": {}
      }),
    )
    .await?;

    send_json_rpc(
      &mut stdin,
      serde_json::json!({
        "method": method,
        "id": request_id,
        "params": params,
      }),
    )
    .await?;

    let response = read_json_rpc_response(&mut lines, request_id).await?;
    if let Some(error) = response.get("error") {
      return Err(json_rpc_error_message(method, error));
    }

    let result = response
      .get("result")
      .cloned()
      .ok_or_else(|| format!("{method} returned no result"))?;
    serde_json::from_value::<TResponse>(result)
      .map_err(|error| format!("Failed to decode {method} response: {error}"))
  }
  .await;

  let _ = child.kill().await;
  let _ = child.wait().await;
  result
}

async fn send_json_rpc(
  stdin: &mut tokio::process::ChildStdin,
  payload: Value,
) -> Result<(), String> {
  let mut bytes =
    serde_json::to_vec(&payload).map_err(|error| format!("Invalid JSON-RPC payload: {error}"))?;
  bytes.push(b'\n');
  stdin
    .write_all(&bytes)
    .await
    .map_err(|error| format!("Failed writing to codex app-server stdin: {error}"))?;
  stdin
    .flush()
    .await
    .map_err(|error| format!("Failed flushing codex app-server stdin: {error}"))?;
  Ok(())
}

async fn read_json_rpc_response(
  lines: &mut tokio::io::Lines<BufReader<ChildStdout>>,
  expected_id: i64,
) -> Result<Value, String> {
  loop {
    let line = tokio::time::timeout(Duration::from_secs(10), lines.next_line())
      .await
      .map_err(|_| "Timed out waiting for codex app-server response".to_string())?
      .map_err(|error| format!("Failed reading codex app-server output: {error}"))?;

    let Some(line) = line else {
      return Err("Codex app-server exited unexpectedly".to_string());
    };

    let trimmed = line.trim();
    if trimmed.is_empty() {
      continue;
    }

    let value: Value = serde_json::from_str(trimmed)
      .map_err(|error| format!("Invalid codex app-server response: {error}"))?;
    if value.get("id").and_then(Value::as_i64) == Some(expected_id) {
      return Ok(value);
    }
  }
}
