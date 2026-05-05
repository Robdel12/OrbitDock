use std::collections::{HashMap, VecDeque};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;

use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::Child;
use tokio::sync::{mpsc, oneshot, Mutex};
use tracing::{error, warn};

use orbitdock_connector_core::{ConnectorError, ConnectorOutput};

use crate::images::transform_image;
use crate::protocol::{
  format_question_answers, ControlRequestBody, ControlResponsePayload, StdinMessage,
  UserContentBlock, UserMessagePayload,
};
use crate::session::{
  ClaudeAllowToolApproval, ClaudeAllowToolApprovalScope, ClaudeDenyToolApproval,
  ClaudeSessionConfig, ClaudeToolApprovalResponse,
};
use crate::stdout::{event_loop, ClaudeEventLoopState, PendingApproval};

/// All tool names (canonical + Claude-specific aliases) that should be
/// pre-approved when the permission mode is `acceptEdits`.
///
/// The Claude CLI can use any of these names interchangeably for file-edit
/// operations. We must include every alias in `--allowedTools` so the CLI
/// doesn't route them through the permission-prompt-tool and cause spurious
/// "Allow for session?" prompts.
pub const ACCEPT_EDITS_TOOLS: &[&str] = &[
  "Edit",
  "Write",
  "NotebookEdit",
  "FileEdit",
  "MultiEdit",
  "FileWrite",
];

/// Returns `true` if `tool_name` is a file-edit tool that `acceptEdits` mode
/// should auto-approve.
pub fn is_accept_edits_tool(tool_name: &str) -> bool {
  ACCEPT_EDITS_TOOLS.contains(&tool_name)
}

pub struct ClaudeConnector {
  stdin_tx: mpsc::Sender<String>,
  child: Arc<Mutex<Child>>,
  output_rx: Option<mpsc::Receiver<ConnectorOutput>>,
  claude_session_id: Arc<Mutex<Option<String>>>,
  pending_controls: Arc<Mutex<HashMap<String, oneshot::Sender<Value>>>>,
  pending_approvals: Arc<Mutex<HashMap<String, PendingApproval>>>,
  cwd: PathBuf,
}

const CLAUDE_STDERR_TAIL_LINES: usize = 5;
const FILE_MENTION_MAX_BYTES: usize = 64 * 1024;

impl ClaudeConnector {
  /// Spawn a new `claude` CLI subprocess.
  pub async fn new(config: &ClaudeSessionConfig<'_>) -> Result<Self, ConnectorError> {
    let claude_bin = resolve_claude_binary()?;

    let mut args = vec![
      "--output-format",
      "stream-json",
      "--verbose",
      "--input-format",
      "stream-json",
      "--permission-prompt-tool",
      "stdio",
      "--replay-user-messages",
    ];

    if let Some(model) = config.model {
      args.extend(["--model", model]);
    }
    if let Some(session_id) = config.resume_id.map(|id| id.as_str()) {
      args.extend(["--resume", session_id]);
    }
    if let Some(mode) = config.permission_mode {
      args.extend(["--permission-mode", mode]);
    }
    if config.allow_bypass_permissions {
      args.push("--allow-dangerously-skip-permissions");
    }

    let mut effective_allowed: Vec<String> = config.allowed_tools.to_vec();
    if config.permission_mode == Some("acceptEdits") {
      for tool in ACCEPT_EDITS_TOOLS {
        let tool = tool.to_string();
        if !effective_allowed.contains(&tool) {
          effective_allowed.push(tool);
        }
      }
    }

    let allowed_joined = effective_allowed.join(",");
    let disallowed_joined = config.disallowed_tools.join(",");
    if !effective_allowed.is_empty() {
      args.extend(["--allowedTools", &allowed_joined]);
    }
    if !config.disallowed_tools.is_empty() {
      args.extend(["--disallowedTools", &disallowed_joined]);
    }
    if let Some(effort) = config.effort {
      args.extend(["--effort", effort]);
    }

    let mut child = tokio::process::Command::new(&claude_bin)
      .args(&args)
      .current_dir(config.cwd)
      .stdin(Stdio::piped())
      .stdout(Stdio::piped())
      .stderr(Stdio::piped())
      .envs(
        config
          .extra_env
          .iter()
          .map(|(key, value)| (key.as_str(), value.as_str())),
      )
      .env("CLAUDE_CODE_ENTRYPOINT", "orbitdock")
      .env("CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING", "true")
      .env_remove("CLAUDECODE")
      .spawn()
      .map_err(|error| {
        error!(
          component = "claude_connector",
          event = "claude.spawn.failed",
          error = %error,
          claude_bin = %claude_bin,
          args = %args.join(" "),
          "Failed to spawn Claude CLI"
        );
        ConnectorError::ProviderError(format!("Failed to spawn claude CLI: {}", error))
      })?;

    let stdin = child
      .stdin
      .take()
      .ok_or_else(|| ConnectorError::ProviderError("No stdin on child".into()))?;
    let stdout = child
      .stdout
      .take()
      .ok_or_else(|| ConnectorError::ProviderError("No stdout on child".into()))?;

    let (output_tx, output_rx) = mpsc::channel::<ConnectorOutput>(256);
    let (stdin_tx, stdin_rx) = mpsc::channel::<String>(256);
    let claude_session_id = Arc::new(Mutex::new(None));
    let pending_controls: Arc<Mutex<HashMap<String, oneshot::Sender<Value>>>> =
      Arc::new(Mutex::new(HashMap::new()));
    let pending_approvals: Arc<Mutex<HashMap<String, PendingApproval>>> =
      Arc::new(Mutex::new(HashMap::new()));

    let child_arc: Arc<Mutex<Child>> = Arc::new(Mutex::new(child));
    let stderr_session_id = config.orbitdock_session_id.to_string();
    if let Some(stderr) = child_arc.lock().await.stderr.take() {
      let child_for_exit = child_arc.clone();
      tokio::spawn(async move {
        let reader = BufReader::new(stderr);
        let mut lines = reader.lines();
        let mut stderr_lines = VecDeque::with_capacity(CLAUDE_STDERR_TAIL_LINES);
        while let Ok(Some(line)) = lines.next_line().await {
          if stderr_lines.len() == CLAUDE_STDERR_TAIL_LINES {
            stderr_lines.pop_front();
          }
          stderr_lines.push_back(line);
        }

        match child_for_exit.lock().await.wait().await {
          Ok(status) => {
            let code = status.code();
            if code != Some(0) {
              warn!(
                component = "claude_connector",
                event = "claude.exit",
                session_id = %stderr_session_id,
                exit_code = ?code,
                stderr_tail = %stderr_lines
                  .iter()
                  .rev()
                  .take(CLAUDE_STDERR_TAIL_LINES)
                  .collect::<Vec<_>>()
                  .into_iter()
                  .rev()
                  .map(|line| line.as_str())
                  .collect::<Vec<_>>()
                  .join("\n"),
                "Claude CLI exited with non-zero status"
              );
            }
          }
          Err(error) => {
            error!(
              component = "claude_connector",
              event = "claude.exit.error",
              session_id = %stderr_session_id,
              error = %error,
              "Failed to get Claude CLI exit status"
            );
          }
        }
      });
    }

    tokio::spawn(async move {
      Self::stdin_writer(stdin, stdin_rx).await;
    });

    let loop_state = ClaudeEventLoopState::new(
      claude_session_id.clone(),
      pending_controls.clone(),
      pending_approvals.clone(),
      stdin_tx.clone(),
      config.orbitdock_session_id.to_string(),
      config.cwd.to_string(),
    );
    tokio::spawn(async move {
      event_loop(stdout, output_tx, loop_state).await;
    });

    let connector = Self {
      stdin_tx,
      child: child_arc,
      output_rx: Some(output_rx),
      claude_session_id,
      pending_controls,
      pending_approvals,
      cwd: PathBuf::from(config.cwd),
    };

    match connector.send_initialize().await {
      Ok(_) => {}
      Err(error) => {
        error!(
          component = "claude_connector",
          event = "claude.init.failed",
          error = %error,
          "Initialize failed, killing orphaned child process"
        );
        let _ = connector.shutdown().await;
        return Err(error);
      }
    }

    Ok(connector)
  }

  /// Take the typed output receiver (can only be called once).
  pub fn take_output_rx(&mut self) -> Option<mpsc::Receiver<ConnectorOutput>> {
    self.output_rx.take()
  }

  /// Get the Claude session ID (set after init event).
  pub async fn claude_session_id(&self) -> Option<String> {
    self.claude_session_id.lock().await.clone()
  }

  /// Send a user message to start or continue a turn.
  pub async fn send_message(
    &self,
    content: &str,
    _model: Option<&str>,
    _effort: Option<&str>,
    images: &[orbitdock_protocol::ImageInput],
    mentions: &[orbitdock_protocol::MentionInput],
  ) -> Result<(), ConnectorError> {
    let mut content_blocks = build_user_content_blocks(content, images, mentions, &self.cwd);

    for image in images {
      match transform_image(image) {
        Ok(block) => content_blocks.push(block),
        Err(error) => {
          warn!(
            event = "claude.image.transform_failed",
            error = %error,
            input_type = %image.input_type,
            "Failed to transform image, skipping"
          );
        }
      }
    }

    let msg = StdinMessage::User {
      session_id: String::new(),
      message: UserMessagePayload {
        role: "user",
        content: content_blocks,
      },
      parent_tool_use_id: None,
    };
    self.write_stdin_message(&msg).await
  }

  /// Interrupt the current turn.
  pub async fn interrupt(&self) -> Result<(), ConnectorError> {
    self
      .send_control_request(ControlRequestBody::Interrupt)
      .await?;
    Ok(())
  }

  /// Approve or deny a tool use request.
  pub async fn approve_tool(
    &self,
    request_id: &str,
    response: ClaudeToolApprovalResponse,
  ) -> Result<(), ConnectorError> {
    let pending = self.pending_approvals.lock().await.remove(request_id);

    let decision = response.label();
    let response_payload = match response {
      ClaudeToolApprovalResponse::Deny(ClaudeDenyToolApproval { message, interrupt }) => {
        let mut deny = serde_json::json!({
          "behavior": "deny",
          "message": message.unwrap_or_else(|| "User denied this operation".to_string()),
          "interrupt": interrupt,
        });
        if let Some(pending) = &pending {
          if let Some(id) = &pending.tool_use_id {
            deny["toolUseID"] = serde_json::json!(id);
          }
        }
        deny
      }
      ClaudeToolApprovalResponse::Allow(ClaudeAllowToolApproval {
        scope,
        updated_input,
      }) => {
        let mut allow = serde_json::json!({
          "behavior": "allow",
        });

        if let Some(pending) = &pending {
          if let Some(updated_input) = updated_input {
            allow["updatedInput"] = updated_input;
          } else {
            allow["updatedInput"] = pending.input.clone();
          }
          if let Some(id) = &pending.tool_use_id {
            allow["toolUseID"] = serde_json::json!(id);
          }

          if matches!(
            scope,
            ClaudeAllowToolApprovalScope::Session | ClaudeAllowToolApprovalScope::Always
          ) {
            if let Some(suggestions) = &pending.permission_suggestions {
              allow["updatedPermissions"] = suggestions.clone();
            } else if let Some(name) = &pending.tool_name {
              let destination = match scope {
                ClaudeAllowToolApprovalScope::Always => "localSettings",
                _ => "session",
              };
              allow["updatedPermissions"] = serde_json::json!([{
                "type": "addRules",
                "behavior": "allow",
                "destination": destination,
                "rules": [{ "toolName": name }]
              }]);
            } else {
              warn!(
                component = "claude_connector",
                event = "claude.approval.missing_permission_suggestions",
                request_id = %request_id,
                decision = %decision,
                tool_use_id = ?pending.tool_use_id,
                "Session-scoped approval missing both permission_suggestions and tool_name; CLI will reprompt"
              );
            }
          }
        } else if matches!(
          scope,
          ClaudeAllowToolApprovalScope::Session | ClaudeAllowToolApprovalScope::Always
        ) {
          warn!(
            component = "claude_connector",
            event = "claude.approval.missing_pending_context",
            request_id = %request_id,
            decision = %decision,
            "Session-scoped approval missing pending request context; cannot attach permission updates"
          );
        }

        allow
      }
    };

    let msg = StdinMessage::ControlResponse {
      response: ControlResponsePayload::Success {
        request_id: request_id.to_string(),
        response: response_payload,
      },
    };
    self.write_stdin_message(&msg).await
  }

  /// Answer a question approval.
  pub async fn answer_question(
    &self,
    request_id: &str,
    answers: &HashMap<String, Vec<String>>,
  ) -> Result<(), ConnectorError> {
    let response_payload = serde_json::json!({
      "behavior": "deny",
      "message": format_question_answers(answers),
      "interrupt": false,
    });

    let msg = StdinMessage::ControlResponse {
      response: ControlResponsePayload::Success {
        request_id: request_id.to_string(),
        response: response_payload,
      },
    };
    self.write_stdin_message(&msg).await
  }

  /// Change the model mid-session.
  pub async fn set_model(&self, model: &str) -> Result<(), ConnectorError> {
    let _ = self
      .send_control_request(ControlRequestBody::SetModel {
        model: Some(model.to_string()),
      })
      .await;
    Ok(())
  }

  /// Change maximum thinking tokens.
  pub async fn set_max_thinking(&self, tokens: u64) -> Result<(), ConnectorError> {
    let _ = self
      .send_control_request(ControlRequestBody::SetMaxThinkingTokens {
        max_thinking_tokens: Some(tokens),
      })
      .await;
    Ok(())
  }

  /// Change permission mode mid-session.
  pub async fn set_permission_mode(&self, mode: &str) -> Result<(), ConnectorError> {
    self
      .send_control_request(ControlRequestBody::SetPermissionMode {
        mode: mode.to_string(),
      })
      .await?;

    if mode == "acceptEdits" {
      let settings = serde_json::json!({ "allowedTools": ACCEPT_EDITS_TOOLS.to_vec() });
      let _ = self
        .send_control_request(ControlRequestBody::ApplyFlagSettings { settings })
        .await;
    }
    Ok(())
  }

  /// Rewind files to a checkpoint (undo file changes from a turn).
  pub async fn rewind_files(
    &self,
    user_message_id: &str,
    dry_run: bool,
  ) -> Result<Value, ConnectorError> {
    self
      .send_control_request(ControlRequestBody::RewindFiles {
        user_message_id: user_message_id.to_string(),
        dry_run: dry_run.then_some(true),
      })
      .await
  }

  /// Stop a running background task/subagent.
  pub async fn stop_task(&self, task_id: &str) -> Result<(), ConnectorError> {
    let _ = self
      .send_control_request(ControlRequestBody::StopTask {
        task_id: task_id.to_string(),
      })
      .await;
    Ok(())
  }

  /// Query MCP server status.
  pub async fn mcp_status(&self) -> Result<Value, ConnectorError> {
    self
      .send_control_request(ControlRequestBody::McpStatus {})
      .await
  }

  /// Reconnect an MCP server.
  pub async fn mcp_reconnect(&self, server_name: &str) -> Result<(), ConnectorError> {
    let _ = self
      .send_control_request(ControlRequestBody::McpReconnect {
        server_name: server_name.to_string(),
      })
      .await;
    Ok(())
  }

  /// Toggle an MCP server on/off.
  pub async fn mcp_toggle(&self, server_name: &str, enabled: bool) -> Result<(), ConnectorError> {
    let _ = self
      .send_control_request(ControlRequestBody::McpToggle {
        server_name: server_name.to_string(),
        enabled,
      })
      .await;
    Ok(())
  }

  /// Authenticate an MCP server (trigger OAuth flow).
  pub async fn mcp_authenticate(&self, server_name: &str) -> Result<(), ConnectorError> {
    let _ = self
      .send_control_request(ControlRequestBody::McpAuthenticate {
        server_name: server_name.to_string(),
      })
      .await;
    Ok(())
  }

  /// Clear authentication for an MCP server.
  pub async fn mcp_clear_auth(&self, server_name: &str) -> Result<(), ConnectorError> {
    let _ = self
      .send_control_request(ControlRequestBody::McpClearAuth {
        server_name: server_name.to_string(),
      })
      .await;
    Ok(())
  }

  /// Set MCP servers configuration.
  pub async fn mcp_set_servers(&self, servers: Value) -> Result<Value, ConnectorError> {
    self
      .send_control_request(ControlRequestBody::McpSetServers { servers })
      .await
  }

  /// Apply flag settings to the session.
  pub async fn apply_flag_settings(&self, settings: Value) -> Result<(), ConnectorError> {
    let _ = self
      .send_control_request(ControlRequestBody::ApplyFlagSettings { settings })
      .await;
    Ok(())
  }

  /// Fetch merged settings from the running Claude session.
  pub async fn get_settings(&self) -> Result<Value, ConnectorError> {
    self
      .send_control_request(ControlRequestBody::GetSettings {})
      .await
  }

  /// Shutdown the subprocess.
  pub async fn shutdown(&self) -> Result<(), ConnectorError> {
    let mut child = self.child.lock().await;
    let _ = child.kill().await;
    Ok(())
  }

  async fn send_initialize(&self) -> Result<Value, ConnectorError> {
    self
      .send_control_request(ControlRequestBody::Initialize {
        system_prompt: None,
        append_system_prompt: None,
        prompt_suggestions: Some(true),
        hooks: None,
        sdk_mcp_servers: None,
        json_schema: None,
        agents: None,
      })
      .await
  }

  async fn send_control_request(&self, body: ControlRequestBody) -> Result<Value, ConnectorError> {
    let id = uuid::Uuid::new_v4().to_string();
    let (tx, rx) = oneshot::channel();
    self.pending_controls.lock().await.insert(id.clone(), tx);

    let msg = StdinMessage::ControlRequest {
      request_id: id.clone(),
      request: body,
    };
    self.write_stdin_message(&msg).await?;

    match tokio::time::timeout(std::time::Duration::from_secs(30), rx).await {
      Ok(Ok(value)) => Ok(value),
      Ok(Err(_)) => {
        self.pending_controls.lock().await.remove(&id);
        Err(ConnectorError::ProviderError(
          "Control response channel dropped".into(),
        ))
      }
      Err(_) => {
        self.pending_controls.lock().await.remove(&id);
        Err(ConnectorError::ProviderError(
          "Control request timed out after 30s".into(),
        ))
      }
    }
  }

  async fn write_stdin_message(&self, msg: &StdinMessage) -> Result<(), ConnectorError> {
    let json = serde_json::to_string(msg).map_err(ConnectorError::JsonError)?;
    self
      .stdin_tx
      .send(json)
      .await
      .map_err(|_| ConnectorError::ProviderError("stdin channel closed".into()))
  }

  /// Dedicated stdin writer task — reads from channel, writes to child stdin.
  async fn stdin_writer(mut stdin: tokio::process::ChildStdin, mut rx: mpsc::Receiver<String>) {
    while let Some(mut line) = rx.recv().await {
      line.push('\n');
      if let Err(error) = stdin.write_all(line.as_bytes()).await {
        error!(
          component = "claude_connector",
          event = "claude.stdin.write_error",
          error = %error,
          "Failed to write to CLI stdin"
        );
        break;
      }
      if let Err(error) = stdin.flush().await {
        error!(
          component = "claude_connector",
          event = "claude.stdin.flush_error",
          error = %error,
          "Failed to flush CLI stdin"
        );
        break;
      }
    }
  }
}

pub(crate) fn build_user_content_blocks(
  content: &str,
  images: &[orbitdock_protocol::ImageInput],
  mentions: &[orbitdock_protocol::MentionInput],
  cwd: &Path,
) -> Vec<UserContentBlock> {
  let mut content_blocks = Vec::new();

  if !content.is_empty() {
    content_blocks.push(UserContentBlock::Text {
      text: content.to_string(),
    });
  }

  if let Some(mention_context) = render_mention_context(mentions, cwd) {
    content_blocks.push(UserContentBlock::Text {
      text: mention_context,
    });
  }

  if content_blocks.is_empty() && images.is_empty() {
    content_blocks.push(UserContentBlock::Text {
      text: String::new(),
    });
  }

  content_blocks
}

fn render_mention_context(
  mentions: &[orbitdock_protocol::MentionInput],
  cwd: &Path,
) -> Option<String> {
  let sections = mentions
    .iter()
    .filter_map(|mention| render_single_mention(mention, cwd))
    .collect::<Vec<_>>();

  if sections.is_empty() {
    None
  } else {
    Some(format!(
      "Attached file context:\n\n{}",
      sections.join("\n\n")
    ))
  }
}

fn render_single_mention(mention: &orbitdock_protocol::MentionInput, cwd: &Path) -> Option<String> {
  let resolved_path = if Path::new(&mention.path).is_absolute() {
    PathBuf::from(&mention.path)
  } else {
    cwd.join(&mention.path)
  };
  let display_path = relative_display_path(&resolved_path, cwd);

  let bytes = match fs::read(&resolved_path) {
    Ok(bytes) => bytes,
    Err(error) => {
      warn!(
        event = "claude.file_mention.read_failed",
        path = %resolved_path.display(),
        error = %error,
        "Failed to read file mention for Claude prompt context"
      );
      return Some(format!(
        "<attached_file path=\"{}\">\n[unavailable: {}]\n</attached_file>",
        escape_tag_attribute(&display_path),
        error
      ));
    }
  };

  if bytes.contains(&0) {
    return Some(format!(
      "<attached_file path=\"{}\">\n[binary file omitted]\n</attached_file>",
      escape_tag_attribute(&display_path)
    ));
  }

  let truncated = bytes.len() > FILE_MENTION_MAX_BYTES;
  let visible = if truncated {
    &bytes[..FILE_MENTION_MAX_BYTES]
  } else {
    &bytes[..]
  };
  let mut body = String::from_utf8_lossy(visible).into_owned();
  if truncated {
    body.push_str("\n[truncated]");
  }

  Some(format!(
    "<attached_file path=\"{}\">\n{}\n</attached_file>",
    escape_tag_attribute(&display_path),
    body
  ))
}

fn relative_display_path(path: &Path, cwd: &Path) -> String {
  path
    .strip_prefix(cwd)
    .unwrap_or(path)
    .display()
    .to_string()
    .replace('\\', "/")
}

fn escape_tag_attribute(value: &str) -> String {
  value
    .replace('&', "&amp;")
    .replace('"', "&quot;")
    .replace('<', "&lt;")
    .replace('>', "&gt;")
}

/// Resolve the claude binary path.
/// 1. CLAUDE_BIN env var
/// 2. ~/.claude/local/claude
/// 3. Search PATH via `which`
fn resolve_claude_binary() -> Result<String, ConnectorError> {
  if let Ok(path) = std::env::var("CLAUDE_BIN") {
    if std::path::Path::new(&path).exists() {
      return Ok(path);
    }
    warn!(
      component = "claude_connector",
      event = "claude.binary.env_not_found",
      path = %path,
      "CLAUDE_BIN path does not exist, trying fallbacks"
    );
  }

  if let Ok(home) = std::env::var("HOME") {
    let local_path = format!("{}/.claude/local/claude", home);
    if std::path::Path::new(&local_path).exists() {
      return Ok(local_path);
    }
  }

  if let Ok(output) = std::process::Command::new("which").arg("claude").output() {
    if output.status.success() {
      let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
      if !path.is_empty() && std::path::Path::new(&path).exists() {
        return Ok(path);
      }
    }
  }

  Err(ConnectorError::ProviderError(
    "Claude CLI binary not found. Install Claude Code or set CLAUDE_BIN.".to_string(),
  ))
}
