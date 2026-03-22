//! Claude CLI Direct connector
//!
//! Spawns the `claude` CLI as a subprocess and communicates via stdin/stdout
//! using the NDJSON stream-json protocol. No Node.js bridge needed.

pub mod session;

use std::collections::HashMap;
use std::process::Stdio;
use std::sync::Arc;

use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use serde::Serialize;
use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::Child;
use tokio::sync::{mpsc, oneshot, Mutex};
use tracing::{debug, error, info, warn};

use orbitdock_connector_core::{ApprovalType, ConnectorError, ConnectorEvent};
use orbitdock_protocol::conversation_contracts::render_hints::RenderHints;
use orbitdock_protocol::conversation_contracts::{
    classify_tool_name, ConversationRow, ConversationRowEntry, MessageRowContent, ToolRow,
};
use orbitdock_protocol::domain_events::{ToolFamily, ToolKind, ToolStatus};
use session::{
    ClaudeAllowToolApproval, ClaudeAllowToolApprovalScope, ClaudeDenyToolApproval,
    ClaudeToolApprovalResponse,
};

// ---------------------------------------------------------------------------
// Tool classification
// ---------------------------------------------------------------------------

/// Classify a raw tool name from the Claude CLI into (ToolFamily, ToolKind).
///
/// Delegates to the shared `classify_tool_name` in orbitdock_protocol, with
/// additional Claude-specific aliases (MultiEdit, FileRead, etc.).
fn classify_tool(name: &str) -> (ToolFamily, ToolKind) {
    // Claude-specific aliases not in the shared classifier
    match name {
        "FileEdit" | "MultiEdit" => return (ToolFamily::FileChange, ToolKind::Edit),
        "FileRead" => return (ToolFamily::FileRead, ToolKind::Read),
        "FileWrite" => return (ToolFamily::FileChange, ToolKind::Write),
        "SendMessage" => return (ToolFamily::Agent, ToolKind::SendAgentInput),
        "TaskCreate" | "TaskUpdate" | "TaskList" | "TaskGet" => {
            return (ToolFamily::Todo, ToolKind::TodoWrite)
        }
        "TaskOutput" => return (ToolFamily::Agent, ToolKind::TaskOutput),
        "TaskStop" => return (ToolFamily::Agent, ToolKind::TaskStop),
        "Skill" => return (ToolFamily::Mcp, ToolKind::McpToolCall),
        "ReadMcpResourceTool" => return (ToolFamily::Mcp, ToolKind::ReadMcpResource),
        "ListMcpResourcesTool" => return (ToolFamily::Mcp, ToolKind::ListMcpResources),
        _ => {}
    }
    classify_tool_name(name)
}

/// Build a flat JSON invocation value from a tool name and optional raw JSON input.
/// For Claude tools, the raw_input IS the flat invocation (e.g. {"command": "ls"}).
fn build_invocation(tool_name: &str, raw_input: Option<&Value>) -> Value {
    match raw_input {
        Some(input) if input.is_object() => input.clone(),
        Some(input) => serde_json::json!({ "tool_name": tool_name, "input": input }),
        None => serde_json::json!({ "tool_name": tool_name }),
    }
}

/// Build a tool title from the tool name (human-friendly).
fn tool_title(tool_name: &str) -> String {
    tool_name.to_string()
}

/// Extract a subtitle from the tool input based on tool kind.
fn extract_subtitle(tool_name: &str, raw_input: Option<&Value>) -> Option<String> {
    let input = raw_input?;
    let result = match tool_name {
        "Bash" | "bash" => {
            let cmd = input.get("command").and_then(Value::as_str).unwrap_or("");
            if cmd.is_empty() {
                return input
                    .get("description")
                    .and_then(Value::as_str)
                    .map(String::from);
            }
            let truncated = if cmd.len() > 120 {
                format!("{}…", &cmd[..120])
            } else {
                cmd.to_string()
            };
            Some(truncated)
        }
        "Read" | "read" | "FileRead" | "Edit" | "edit" | "FileEdit" | "MultiEdit" | "Write"
        | "write" | "FileWrite" | "NotebookEdit" => input
            .get("file_path")
            .and_then(Value::as_str)
            .map(String::from),
        "Glob" | "glob" => input
            .get("pattern")
            .and_then(Value::as_str)
            .map(String::from),
        "Grep" | "grep" => input
            .get("pattern")
            .and_then(Value::as_str)
            .map(String::from),
        "WebSearch" | "websearch" => input.get("query").and_then(Value::as_str).map(String::from),
        "WebFetch" | "webfetch" => input.get("url").and_then(Value::as_str).map(String::from),
        "Agent" | "agent" => {
            let desc = input.get("description").and_then(Value::as_str);
            let agent_type = input.get("subagent_type").and_then(Value::as_str);
            match (agent_type, desc) {
                (Some(t), Some(d)) => Some(format!("{t} — {d}")),
                (Some(t), None) => Some(t.to_string()),
                (None, Some(d)) => Some(d.to_string()),
                _ => None,
            }
        }
        n if n.starts_with("mcp__") => {
            // mcp__server__tool → "server · tool"
            let parts: Vec<&str> = n
                .strip_prefix("mcp__")
                .unwrap_or(n)
                .splitn(2, "__")
                .collect();
            match parts.as_slice() {
                [server, tool] => Some(format!("{server} · {tool}")),
                _ => None,
            }
        }
        _ => None,
    };
    // Ensure we don't return empty strings
    result.filter(|s| !s.trim().is_empty())
}

/// Extract an ImageInput from an Anthropic image content block.
///
/// Claude Code JSONL user messages contain image blocks in the Anthropic API
/// format:
/// ```json
/// {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "..."}}
/// {"type": "image", "source": {"type": "url", "url": "https://..."}}
/// ```
fn extract_image_input(block: &Value) -> Option<orbitdock_protocol::ImageInput> {
    let source = block.get("source")?;
    let source_type = source.get("type").and_then(|v| v.as_str())?;

    match source_type {
        "base64" => {
            let media_type = source
                .get("media_type")
                .and_then(|v| v.as_str())
                .unwrap_or("image/png");
            let data = source.get("data").and_then(|v| v.as_str())?;
            // Construct a data URI for the client to decode
            let data_uri = format!("data:{};base64,{}", media_type, data);
            let byte_count = (data.len() * 3 / 4) as u64;
            Some(orbitdock_protocol::ImageInput {
                input_type: "url".to_string(),
                value: data_uri,
                mime_type: Some(media_type.to_string()),
                byte_count: Some(byte_count),
                display_name: None,
                pixel_width: None,
                pixel_height: None,
            })
        }
        "url" => {
            let url = source.get("url").and_then(|v| v.as_str())?;
            Some(orbitdock_protocol::ImageInput {
                input_type: "url".to_string(),
                value: url.to_string(),
                mime_type: None,
                byte_count: None,
                display_name: None,
                pixel_width: None,
                pixel_height: None,
            })
        }
        _ => None,
    }
}

/// Compute a summary from tool result output.
fn extract_result_summary(tool_name: &str, output: &str) -> Option<String> {
    if output.is_empty() {
        return None;
    }
    let summary = match tool_name {
        "Bash" | "bash" => {
            let first_line = output.lines().next().unwrap_or("");
            if first_line.len() > 200 {
                format!("{}…", &first_line[..200])
            } else {
                first_line.to_string()
            }
        }
        "Read" | "read" | "FileRead" => {
            let line_count = output.lines().count();
            format!("{line_count} lines")
        }
        "Edit" | "edit" | "FileEdit" | "MultiEdit" => {
            let has_diff = output.contains("@@") || output.contains("+") || output.contains("-");
            if has_diff {
                let additions = output.lines().filter(|l| l.starts_with('+')).count();
                let deletions = output.lines().filter(|l| l.starts_with('-')).count();
                format!("+{additions} -{deletions}")
            } else {
                "Applied".to_string()
            }
        }
        "Write" | "write" | "FileWrite" => "Created file".to_string(),
        "Glob" | "glob" => {
            let count = output.lines().filter(|l| !l.trim().is_empty()).count();
            format!("{count} files matched")
        }
        "Grep" | "grep" => {
            let non_empty: Vec<&str> = output.lines().filter(|l| !l.trim().is_empty()).collect();
            let file_count = non_empty
                .iter()
                .filter_map(|l| l.split(':').next())
                .collect::<std::collections::HashSet<_>>()
                .len();
            format!("{} matches in {} files", non_empty.len(), file_count)
        }
        _ => {
            let first_line = output.lines().next().unwrap_or("");
            // Guard against raw JSON leaking into summaries
            if first_line.starts_with('[') || first_line.starts_with('{') {
                return None;
            }
            if first_line.len() > 200 {
                format!("{}…", &first_line[..200])
            } else {
                first_line.to_string()
            }
        }
    };
    if summary.trim().is_empty() {
        None
    } else {
        Some(summary)
    }
}

/// Compute render hints based on tool kind.
fn tool_render_hints(kind: ToolKind) -> RenderHints {
    match kind {
        ToolKind::Bash => RenderHints {
            can_expand: true,
            monospace_summary: true,
            ..Default::default()
        },
        ToolKind::Read | ToolKind::Edit | ToolKind::Write | ToolKind::NotebookEdit => RenderHints {
            can_expand: true,
            ..Default::default()
        },
        ToolKind::Grep | ToolKind::Glob => RenderHints {
            can_expand: true,
            ..Default::default()
        },
        _ => RenderHints::default(),
    }
}

/// Construct a ToolRow for a newly-created tool use.
fn make_tool_row(
    id: String,
    tool_name: &str,
    raw_input: Option<&Value>,
    status: ToolStatus,
) -> ToolRow {
    let (family, kind) = classify_tool(tool_name);
    let subtitle = extract_subtitle(tool_name, raw_input);
    let render_hints = tool_render_hints(kind);
    let tool_display = Some(
        orbitdock_protocol::conversation_contracts::compute_tool_display(
            orbitdock_protocol::conversation_contracts::ToolDisplayInput {
                kind,
                family,
                status,
                title: tool_name,
                subtitle: subtitle.as_deref(),
                summary: None,
                duration_ms: None,
                invocation_input: raw_input,
                result_output: None,
            },
        ),
    );
    ToolRow {
        id,
        provider: orbitdock_protocol::Provider::Claude,
        family,
        kind,
        status,
        title: tool_title(tool_name),
        subtitle,
        summary: None,
        preview: None,
        started_at: Some(now_iso()),
        ended_at: None,
        duration_ms: None,
        grouping_key: None,
        invocation: build_invocation(tool_name, raw_input),
        result: None,
        render_hints,
        tool_display,
    }
}

/// Wrap a ConversationRow in a ConversationRowEntry.
fn make_entry(session_id: &str, row: ConversationRow) -> ConversationRowEntry {
    ConversationRowEntry {
        session_id: session_id.to_string(),
        sequence: 0,
        turn_id: None,
        row,
    }
}

// ---------------------------------------------------------------------------
// Stdin messages (Rust → CLI)
// ---------------------------------------------------------------------------

#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum StdinMessage {
    User {
        session_id: String,
        message: UserMessagePayload,
        #[serde(skip_serializing_if = "Option::is_none")]
        parent_tool_use_id: Option<String>,
    },
    ControlRequest {
        request_id: String,
        request: ControlRequestBody,
    },
    ControlResponse {
        response: ControlResponsePayload,
    },
}

#[derive(Debug, Serialize)]
struct UserMessagePayload {
    role: &'static str,
    content: Vec<UserContentBlock>,
}

#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum UserContentBlock {
    Text { text: String },
    Image { source: ImageSource },
}

#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum ImageSource {
    Base64 {
        media_type: String,
        data: String,
    },
    #[serde(rename = "url")]
    Url {
        url: String,
    },
}

#[derive(Debug, Serialize)]
#[serde(tag = "subtype", rename_all = "snake_case")]
enum ControlRequestBody {
    Initialize {
        #[serde(skip_serializing_if = "Option::is_none")]
        system_prompt: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        append_system_prompt: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        prompt_suggestions: Option<bool>,
        /// Hook callback registrations: `{ hookEvent: [{ matcher?, hookCallbackIds, timeout? }] }`
        #[serde(skip_serializing_if = "Option::is_none")]
        hooks: Option<Value>,
        /// MCP servers registered by the SDK host (server names)
        #[serde(rename = "sdkMcpServers", skip_serializing_if = "Option::is_none")]
        sdk_mcp_servers: Option<Vec<String>>,
        /// Custom JSON schemas
        #[serde(rename = "jsonSchema", skip_serializing_if = "Option::is_none")]
        json_schema: Option<Value>,
        /// Agent definitions
        #[serde(skip_serializing_if = "Option::is_none")]
        agents: Option<Value>,
    },
    Interrupt,
    SetModel {
        model: Option<String>,
    },
    SetMaxThinkingTokens {
        max_thinking_tokens: Option<u64>,
    },
    SetPermissionMode {
        mode: String,
    },
    RewindFiles {
        user_message_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        dry_run: Option<bool>,
    },
    StopTask {
        task_id: String,
    },
    McpStatus {},
    McpReconnect {
        #[serde(rename = "serverName")]
        server_name: String,
    },
    McpToggle {
        #[serde(rename = "serverName")]
        server_name: String,
        enabled: bool,
    },
    McpAuthenticate {
        #[serde(rename = "serverName")]
        server_name: String,
    },
    McpClearAuth {
        #[serde(rename = "serverName")]
        server_name: String,
    },
    McpSetServers {
        servers: Value,
    },
    ApplyFlagSettings {
        settings: Value,
    },
    GetSettings {},
}

#[derive(Debug, Serialize)]
#[serde(tag = "subtype", rename_all = "snake_case")]
#[allow(dead_code)]
enum ControlResponsePayload {
    Success { request_id: String, response: Value },
    Error { request_id: String, error: String },
}

// ---------------------------------------------------------------------------
// Image transformation helper
// ---------------------------------------------------------------------------

/// Transform ImageInput to Anthropic's image content block format.
/// - URL images: pass through as-is
/// - Path images: read file, convert to base64
fn transform_image(image: &orbitdock_protocol::ImageInput) -> Result<UserContentBlock, String> {
    match image.input_type.as_str() {
        "url" => {
            if let Some((media_type, data)) = parse_data_uri_base64(&image.value) {
                Ok(UserContentBlock::Image {
                    source: ImageSource::Base64 { media_type, data },
                })
            } else {
                Ok(UserContentBlock::Image {
                    source: ImageSource::Url {
                        url: image.value.clone(),
                    },
                })
            }
        }
        "path" => {
            // Read file from disk
            let bytes = std::fs::read(&image.value)
                .map_err(|e| format!("Failed to read image file {}: {}", image.value, e))?;

            // Infer media type from file extension
            let media_type = infer_media_type(&image.value);

            // Encode to base64
            let data = STANDARD.encode(&bytes);

            Ok(UserContentBlock::Image {
                source: ImageSource::Base64 { media_type, data },
            })
        }
        other => Err(format!("Unknown image input_type: {}", other)),
    }
}

/// Parse a `data:*;base64,...` URI into `(media_type, base64_data)`.
fn parse_data_uri_base64(uri: &str) -> Option<(String, String)> {
    let without_scheme = uri.strip_prefix("data:")?;
    let comma_pos = without_scheme.find(',')?;
    let meta = &without_scheme[..comma_pos];
    if !meta.ends_with(";base64") {
        return None;
    }

    let media_type = &meta[..meta.len() - 7];
    let normalized_media_type = if media_type.is_empty() {
        "image/png"
    } else {
        media_type
    };

    let raw_data = &without_scheme[comma_pos + 1..];
    let normalized_data: String = raw_data
        .chars()
        .filter(|c| !c.is_ascii_whitespace())
        .collect();
    if normalized_data.is_empty() {
        return None;
    }

    Some((normalized_media_type.to_string(), normalized_data))
}

/// Infer MIME type from file path extension.
fn infer_media_type(path: &str) -> String {
    let path_lower = path.to_lowercase();
    if path_lower.ends_with(".png") {
        "image/png".to_string()
    } else if path_lower.ends_with(".jpg") || path_lower.ends_with(".jpeg") {
        "image/jpeg".to_string()
    } else if path_lower.ends_with(".gif") {
        "image/gif".to_string()
    } else if path_lower.ends_with(".webp") {
        "image/webp".to_string()
    } else {
        // Default to PNG for unknown types
        "image/png".to_string()
    }
}

// ---------------------------------------------------------------------------
// ClaudeConnector
// ---------------------------------------------------------------------------

/// Stores the `input`, `tool_use_id`, and `permission_suggestions` from a
/// `can_use_tool` control request so we can echo them back in the approval
/// response (required by the SDK).
struct PendingApproval {
    input: Value,
    tool_use_id: Option<String>,
    permission_suggestions: Option<Value>,
}

#[allow(dead_code)]
pub struct ClaudeConnector {
    stdin_tx: mpsc::Sender<String>,
    child: Arc<Mutex<Child>>,
    event_rx: Option<mpsc::Receiver<ConnectorEvent>>,
    claude_session_id: Arc<Mutex<Option<String>>>,
    pending_controls: Arc<Mutex<HashMap<String, oneshot::Sender<Value>>>>,
    pending_approvals: Arc<Mutex<HashMap<String, PendingApproval>>>,
}

impl ClaudeConnector {
    /// Spawn a new `claude` CLI subprocess.
    #[allow(clippy::too_many_arguments)]
    pub async fn new(
        cwd: &str,
        model: Option<&str>,
        resume_id: Option<&str>,
        permission_mode: Option<&str>,
        allowed_tools: &[String],
        disallowed_tools: &[String],
        effort: Option<&str>,
        allow_bypass_permissions: bool,
    ) -> Result<Self, ConnectorError> {
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

        if let Some(m) = model {
            args.extend(["--model", m]);
        }
        if let Some(sid) = resume_id {
            args.extend(["--resume", sid]);
        }
        if let Some(mode) = permission_mode {
            args.extend(["--permission-mode", mode]);
        }
        if allow_bypass_permissions {
            args.push("--allow-dangerously-skip-permissions");
        }

        // When permission_mode is "acceptEdits", ensure edit tools are explicitly
        // in the allowedTools list. The --permission-prompt-tool stdio flag routes
        // ALL permission decisions through the control protocol, so the CLI's
        // internal --permission-mode auto-accept logic may not fire. Passing them
        // as --allowedTools guarantees the CLI pre-approves them.
        let mut effective_allowed: Vec<String> = allowed_tools.to_vec();
        if permission_mode == Some("acceptEdits") {
            for tool in ["Edit", "Write", "NotebookEdit"] {
                let tool_str = tool.to_string();
                if !effective_allowed.contains(&tool_str) {
                    effective_allowed.push(tool_str);
                }
            }
        }

        let allowed_joined = effective_allowed.join(",");
        let disallowed_joined = disallowed_tools.join(",");
        if !effective_allowed.is_empty() {
            args.extend(["--allowedTools", &allowed_joined]);
        }
        if !disallowed_tools.is_empty() {
            args.extend(["--disallowedTools", &disallowed_joined]);
        }
        if let Some(e) = effort {
            args.extend(["--effort", e]);
        }

        let args_display = args.join(" ");
        info!(
            component = "claude_connector",
            event = "claude.spawn",
            cwd = %cwd,
            claude_bin = %claude_bin,
            resume_id = ?resume_id,
            args = %args_display,
            "Spawning Claude CLI directly"
        );

        let mut child = tokio::process::Command::new(&claude_bin)
            .args(&args)
            .current_dir(cwd)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .env("CLAUDE_CODE_ENTRYPOINT", "orbitdock")
            .env("CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING", "true")
            .env_remove("CLAUDECODE")
            .spawn()
            .map_err(|e| {
                error!(
                    component = "claude_connector",
                    event = "claude.spawn.failed",
                    error = %e,
                    claude_bin = %claude_bin,
                    args = %args_display,
                    "Failed to spawn Claude CLI"
                );
                ConnectorError::ProviderError(format!("Failed to spawn claude CLI: {}", e))
            })?;

        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| ConnectorError::ProviderError("No stdin on child".into()))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| ConnectorError::ProviderError("No stdout on child".into()))?;

        let (event_tx, event_rx) = mpsc::channel::<ConnectorEvent>(256);
        let (stdin_tx, stdin_rx) = mpsc::channel::<String>(256);
        let claude_session_id = Arc::new(Mutex::new(None));
        let pending_controls: Arc<Mutex<HashMap<String, oneshot::Sender<Value>>>> =
            Arc::new(Mutex::new(HashMap::new()));
        let pending_approvals: Arc<Mutex<HashMap<String, PendingApproval>>> =
            Arc::new(Mutex::new(HashMap::new()));

        // Spawn stderr reader + exit code watcher
        let child_arc: Arc<Mutex<Child>> = Arc::new(Mutex::new(child));
        if let Some(stderr) = child_arc.lock().await.stderr.take() {
            let child_for_exit = child_arc.clone();
            tokio::spawn(async move {
                let reader = BufReader::new(stderr);
                let mut lines = reader.lines();
                let mut stderr_lines = Vec::new();
                while let Ok(Some(line)) = lines.next_line().await {
                    warn!(
                        component = "claude_connector",
                        event = "claude.stderr",
                        line = %line,
                        "Claude CLI stderr"
                    );
                    stderr_lines.push(line);
                }
                // stderr closed — process is exiting, capture exit code
                let exit_status = child_for_exit.lock().await.wait().await;
                match exit_status {
                    Ok(status) => {
                        let code = status.code();
                        if code != Some(0) {
                            warn!(
                                component = "claude_connector",
                                event = "claude.exit",
                                exit_code = ?code,
                                stderr_tail = %stderr_lines.iter().rev().take(5)
                                    .collect::<Vec<_>>().into_iter().rev()
                                    .cloned().collect::<Vec<_>>().join("\n"),
                                "Claude CLI exited with non-zero status"
                            );
                        } else {
                            info!(
                                component = "claude_connector",
                                event = "claude.exit",
                                exit_code = ?code,
                                "Claude CLI exited"
                            );
                        }
                    }
                    Err(e) => {
                        error!(
                            component = "claude_connector",
                            event = "claude.exit.error",
                            error = %e,
                            "Failed to get Claude CLI exit status"
                        );
                    }
                }
            });
        }

        // Spawn stdin writer task
        tokio::spawn(async move {
            Self::stdin_writer(stdin, stdin_rx).await;
        });

        // Spawn stdout reader loop
        let session_clone = claude_session_id.clone();
        let pending_clone = pending_controls.clone();
        let approvals_clone = pending_approvals.clone();
        let stdin_tx_for_loop = stdin_tx.clone();

        tokio::spawn(async move {
            Self::event_loop(
                stdout,
                event_tx,
                session_clone,
                pending_clone,
                approvals_clone,
                stdin_tx_for_loop,
            )
            .await;
        });

        let connector = Self {
            stdin_tx,
            child: child_arc,
            event_rx: Some(event_rx),
            claude_session_id,
            pending_controls,
            pending_approvals,
        };

        // Send initialize control request — kill the child if it fails
        match connector.send_initialize().await {
            Ok(_init_response) => {
                debug!(
                    component = "claude_connector",
                    event = "claude.init.response",
                    "Initialize response received"
                );
            }
            Err(e) => {
                error!(
                    component = "claude_connector",
                    event = "claude.init.failed",
                    error = %e,
                    "Initialize failed, killing orphaned child process"
                );
                let _ = connector.shutdown().await;
                return Err(e);
            }
        }

        Ok(connector)
    }

    /// Take the event receiver (can only be called once).
    pub fn take_event_rx(&mut self) -> Option<mpsc::Receiver<ConnectorEvent>> {
        self.event_rx.take()
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
    ) -> Result<(), ConnectorError> {
        let mut content_blocks = vec![UserContentBlock::Text {
            text: content.to_string(),
        }];

        // Transform images to Anthropic format
        for image in images {
            match transform_image(image) {
                Ok(block) => content_blocks.push(block),
                Err(e) => {
                    warn!(
                        event = "claude.image.transform_failed",
                        error = %e,
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
        self.send_control_request(ControlRequestBody::Interrupt)
            .await?;
        Ok(())
    }

    /// Approve or deny a tool use request.
    ///
    /// - `message`: Custom deny reason shown to the agent (deny only).
    /// - `interrupt`: If true, stop the entire turn instead of just this tool.
    /// - `updated_input`: Modified tool input to use instead of the original.
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
                if let Some(ref p) = pending {
                    if let Some(ref id) = p.tool_use_id {
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
                if let Some(ref p) = pending {
                    // Use client-provided updated_input if present, otherwise echo original
                    if let Some(ui) = updated_input {
                        allow["updatedInput"] = ui;
                    } else {
                        allow["updatedInput"] = p.input.clone();
                    }
                    if let Some(ref id) = p.tool_use_id {
                        allow["toolUseID"] = serde_json::json!(id);
                    }
                    if matches!(
                        scope,
                        ClaudeAllowToolApprovalScope::Session
                            | ClaudeAllowToolApprovalScope::Always
                    ) {
                        if let Some(ref suggestions) = p.permission_suggestions {
                            allow["updatedPermissions"] = suggestions.clone();
                        } else {
                            warn!(
                                component = "claude_connector",
                                event = "claude.approval.missing_permission_suggestions",
                                request_id = %request_id,
                                decision = %decision,
                                tool_use_id = ?p.tool_use_id,
                                "Session-scoped approval missing permission suggestions; CLI may reprompt the same command"
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
    ///
    /// The SDK's `AskUserQuestion` tool uses `can_use_tool` control_request.
    /// We respond with `behavior: "deny"` and the answer in `message`.
    /// For structured multi-question answers, format as JSON matching
    /// `AskUserQuestionOutput.answers` (`{ question_text: "value" }`).
    pub async fn answer_question(
        &self,
        request_id: &str,
        answers: &HashMap<String, Vec<String>>,
    ) -> Result<(), ConnectorError> {
        let message = format_question_answers(answers);

        let response_payload = serde_json::json!({
            "behavior": "deny",
            "message": message,
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
        self.send_control_request(ControlRequestBody::SetPermissionMode {
            mode: mode.to_string(),
        })
        .await?;
        Ok(())
    }

    /// Rewind files to a checkpoint (undo file changes from a turn).
    pub async fn rewind_files(
        &self,
        user_message_id: &str,
        dry_run: bool,
    ) -> Result<Value, ConnectorError> {
        self.send_control_request(ControlRequestBody::RewindFiles {
            user_message_id: user_message_id.to_string(),
            dry_run: if dry_run { Some(true) } else { None },
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
        self.send_control_request(ControlRequestBody::McpStatus {})
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
        self.send_control_request(ControlRequestBody::McpSetServers { servers })
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
        self.send_control_request(ControlRequestBody::GetSettings {})
            .await
    }

    /// Shutdown the subprocess.
    pub async fn shutdown(&self) -> Result<(), ConnectorError> {
        // Drop the stdin sender to close the pipe, which signals the CLI to exit
        // (The sender is held by the stdin_writer task, which will end when the
        // channel closes. We can't drop it directly, but killing the child works.)
        let mut child = self.child.lock().await;
        let _ = child.kill().await;
        Ok(())
    }

    // -- Internal helpers ---------------------------------------------------

    /// Send the initialize control request with enriched fields.
    async fn send_initialize(&self) -> Result<Value, ConnectorError> {
        self.send_control_request(ControlRequestBody::Initialize {
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

    /// Send a control request and wait for the response.
    async fn send_control_request(
        &self,
        body: ControlRequestBody,
    ) -> Result<Value, ConnectorError> {
        let id = uuid::Uuid::new_v4().to_string();
        let (tx, rx) = oneshot::channel();
        self.pending_controls.lock().await.insert(id.clone(), tx);

        let msg = StdinMessage::ControlRequest {
            request_id: id.clone(),
            request: body,
        };
        self.write_stdin_message(&msg).await?;

        match tokio::time::timeout(std::time::Duration::from_secs(30), rx).await {
            Ok(Ok(val)) => Ok(val),
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

    /// Serialize and send a message to the stdin channel.
    async fn write_stdin_message(&self, msg: &StdinMessage) -> Result<(), ConnectorError> {
        let json = serde_json::to_string(msg).map_err(ConnectorError::JsonError)?;

        debug!(
            component = "claude_connector",
            event = "claude.stdin.write",
            payload_len = json.len(),
            "Writing to CLI stdin"
        );

        self.stdin_tx
            .send(json)
            .await
            .map_err(|_| ConnectorError::ProviderError("stdin channel closed".into()))
    }

    /// Dedicated stdin writer task — reads from channel, writes to child stdin.
    async fn stdin_writer(mut stdin: tokio::process::ChildStdin, mut rx: mpsc::Receiver<String>) {
        while let Some(mut line) = rx.recv().await {
            line.push('\n');
            if let Err(e) = stdin.write_all(line.as_bytes()).await {
                error!(
                    component = "claude_connector",
                    event = "claude.stdin.write_error",
                    error = %e,
                    "Failed to write to CLI stdin"
                );
                break;
            }
            if let Err(e) = stdin.flush().await {
                error!(
                    component = "claude_connector",
                    event = "claude.stdin.flush_error",
                    error = %e,
                    "Failed to flush CLI stdin"
                );
                break;
            }
        }
        debug!(
            component = "claude_connector",
            event = "claude.stdin.closed",
            "Stdin writer task ended"
        );
    }

    /// Read stdout line-by-line, parse JSON, translate to ConnectorEvent.
    #[allow(clippy::too_many_arguments)]
    async fn event_loop(
        stdout: tokio::process::ChildStdout,
        event_tx: mpsc::Sender<ConnectorEvent>,
        session_id: Arc<Mutex<Option<String>>>,
        pending_controls: Arc<Mutex<HashMap<String, oneshot::Sender<Value>>>>,
        pending_approvals: Arc<Mutex<HashMap<String, PendingApproval>>>,
        stdin_tx: mpsc::Sender<String>,
    ) {
        let reader = BufReader::new(stdout);
        let mut lines = reader.lines();
        let mut streaming_content = String::new();
        let mut streaming_msg_id: Option<String> = None;
        let mut in_turn = false;
        let mut turn_patch_diffs: Vec<String> = Vec::new();
        // Per-call input/cached tokens from the latest assistant message (for accurate context fill)
        let mut last_turn_input: Option<(u64, u64)> = None;
        let mut cumulative_output: u64 = 0;
        let mut last_context_window: u64 = 1_000_000;
        // Maps tool_use_id → task_id so we can finalize task cards when
        // the Agent tool_result arrives (CLI never emits task_notification).
        let mut task_tool_use_map: HashMap<String, String> = HashMap::new();
        // Tracks the in-progress "Compacting context…" message ID so
        // compact_boundary can finalize it.
        let mut compacting_msg_id: Option<String> = None;
        // Tracks live ToolRow state so we can reconstruct full
        // ConversationRowEntry on updates.
        let mut tool_rows: HashMap<String, ToolRow> = HashMap::new();

        let mut line_count: u64 = 0;

        loop {
            match lines.next_line().await {
                Ok(Some(line)) => {
                    line_count += 1;
                    let line = line.trim().to_string();
                    if line.is_empty() {
                        continue;
                    }

                    // Log first few lines and any non-JSON for debugging startup issues
                    if line_count <= 3 {
                        info!(
                            component = "claude_connector",
                            event = "claude.stdout.raw",
                            line_num = line_count,
                            preview = %if line.len() > 300 { &line[..300] } else { &line },
                            "Raw stdout line"
                        );
                    }

                    let raw: Value = match serde_json::from_str(&line) {
                        Ok(v) => v,
                        Err(e) => {
                            warn!(
                                component = "claude_connector",
                                event = "claude.stdout.parse_error",
                                error = %e,
                                line_preview = %if line.len() > 200 { &line[..200] } else { &line },
                                "Failed to parse stdout JSON"
                            );
                            continue;
                        }
                    };

                    let events = Self::dispatch_stdout_message(
                        &raw,
                        &session_id,
                        &pending_controls,
                        &pending_approvals,
                        &mut streaming_content,
                        &mut streaming_msg_id,
                        &mut in_turn,
                        &mut turn_patch_diffs,
                        &mut last_turn_input,
                        &mut cumulative_output,
                        &mut last_context_window,
                        &stdin_tx,
                        &mut task_tool_use_map,
                        &mut compacting_msg_id,
                        &mut tool_rows,
                    )
                    .await;

                    for ev in events {
                        if event_tx.send(ev).await.is_err() {
                            info!(
                                component = "claude_connector",
                                event = "claude.event_loop.channel_closed",
                                "Event channel closed, stopping reader"
                            );
                            return;
                        }
                    }
                }
                Ok(None) => {
                    warn!(
                        component = "claude_connector",
                        event = "claude.stdout.eof",
                        lines_read = line_count,
                        "Claude CLI stdout EOF"
                    );
                    let _ = event_tx
                        .send(ConnectorEvent::SessionEnded {
                            reason: "cli_exited".to_string(),
                        })
                        .await;
                    return;
                }
                Err(e) => {
                    error!(
                        component = "claude_connector",
                        event = "claude.stdout.read_error",
                        error = %e,
                        "Error reading CLI stdout"
                    );
                    let _ = event_tx
                        .send(ConnectorEvent::SessionEnded {
                            reason: format!("read_error: {}", e),
                        })
                        .await;
                    return;
                }
            }
        }
    }

    /// Dispatch a raw stdout JSON message by its `type` field.
    #[allow(clippy::too_many_arguments)]
    async fn dispatch_stdout_message(
        raw: &Value,
        session_id_slot: &Arc<Mutex<Option<String>>>,
        pending_controls: &Arc<Mutex<HashMap<String, oneshot::Sender<Value>>>>,
        pending_approvals: &Arc<Mutex<HashMap<String, PendingApproval>>>,
        streaming_content: &mut String,
        streaming_msg_id: &mut Option<String>,
        in_turn: &mut bool,
        turn_patch_diffs: &mut Vec<String>,
        last_turn_input: &mut Option<(u64, u64)>,
        cumulative_output: &mut u64,
        last_context_window: &mut u64,
        stdin_tx: &mpsc::Sender<String>,
        task_tool_use_map: &mut HashMap<String, String>,
        compacting_msg_id: &mut Option<String>,
        tool_rows: &mut HashMap<String, ToolRow>,
    ) -> Vec<ConnectorEvent> {
        let msg_type = raw.get("type").and_then(|v| v.as_str()).unwrap_or("");
        let session_id = session_id_slot.lock().await.clone().unwrap_or_default();

        let is_replay = raw
            .get("isReplay")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);

        debug!(
            component = "claude_connector",
            event = "claude.stdout.dispatch",
            msg_type = %msg_type,
            session_id = %session_id,
            is_replay = is_replay,
            "Dispatching stdout message"
        );

        // Skip replayed messages from --resume. Only allow `system` through
        // (contains init with session_id, hook_started for thread registration).
        if is_replay && msg_type != "system" {
            return vec![];
        }

        // Emit TurnStarted on first assistant activity (stream_event or assistant message)
        let mut turn_start_event = Vec::new();
        if !*in_turn && matches!(msg_type, "assistant" | "stream_event") {
            *in_turn = true;
            turn_patch_diffs.clear();
            turn_start_event.push(ConnectorEvent::TurnStarted);
        }

        let mut events = match msg_type {
            "system" => {
                Self::handle_system_message(
                    raw,
                    session_id_slot,
                    task_tool_use_map,
                    compacting_msg_id,
                    tool_rows,
                )
                .await
            }

            "assistant" => Self::handle_assistant_message(
                raw,
                &session_id,
                streaming_content,
                streaming_msg_id,
                turn_patch_diffs,
                last_turn_input,
                cumulative_output,
                last_context_window,
                tool_rows,
            ),

            "user" => Self::handle_user_message(raw, &session_id, task_tool_use_map, tool_rows),

            "stream_event" => {
                Self::handle_stream_event(raw, &session_id, streaming_content, streaming_msg_id)
            }

            "tool_progress" => Self::handle_tool_progress(raw, &session_id, tool_rows),

            "result" => {
                *in_turn = false;
                turn_patch_diffs.clear();
                Self::handle_result_message(
                    raw,
                    streaming_content,
                    streaming_msg_id,
                    last_turn_input,
                    cumulative_output,
                    last_context_window,
                    &session_id,
                )
            }

            "control_request" => {
                Self::handle_cli_control_request(raw, pending_approvals, stdin_tx).await
            }

            "control_cancel_request" => {
                // CLI cancelled a pending approval — clean up stored data and
                // notify the server so the approval card is cleared.
                if let Some(req_id) = string_field(raw, "request_id", "requestId") {
                    pending_approvals.lock().await.remove(req_id.as_str());
                    info!(
                        component = "claude_connector",
                        event = "claude.control.cancelled",
                        request_id = %req_id,
                        "CLI cancelled control request"
                    );
                    vec![ConnectorEvent::ApprovalCancelled { request_id: req_id }]
                } else {
                    vec![]
                }
            }

            "control_response" => {
                Self::handle_control_response(raw, pending_controls).await;
                vec![]
            }

            "status" => {
                // SDK status messages carry permission_mode changes and compacting state.
                // May arrive as top-level type="status" or as system subtype="status".
                let mut status_events = vec![];
                if let Some(mode) = raw
                    .get("permission_mode")
                    .or_else(|| raw.get("permissionMode"))
                    .and_then(Value::as_str)
                {
                    info!(
                        component = "claude_connector",
                        event = "claude.permission_mode.changed",
                        mode = %mode,
                        "Permission mode changed via status message"
                    );
                    status_events.push(ConnectorEvent::PermissionModeChanged {
                        mode: mode.to_string(),
                    });
                }
                status_events
            }

            "tool_use_summary" => {
                // Human-readable summary of preceding tool uses.
                let summary = raw.get("summary").and_then(Value::as_str).unwrap_or("");
                if summary.is_empty() {
                    vec![]
                } else {
                    let id = format!("claude-summary-{}", uuid::Uuid::new_v4());
                    let row = ConversationRow::Assistant(MessageRowContent {
                        id,
                        content: summary.to_string(),
                        turn_id: None,
                        timestamp: Some(now_iso()),
                        is_streaming: false,
                        images: vec![],
                        memory_citation: None,
                    });
                    vec![ConnectorEvent::ConversationRowCreated(make_entry(
                        &session_id,
                        row,
                    ))]
                }
            }

            "rate_limit_event" => {
                let rate_limit_info = raw.get("rate_limit_info").unwrap_or(raw);
                let status = rate_limit_info
                    .get("status")
                    .and_then(|v| v.as_str())
                    .unwrap_or("allowed")
                    .to_string();
                let resets_at = rate_limit_info
                    .get("resets_at")
                    .and_then(|v| v.as_str())
                    .map(String::from);
                let rate_limit_type = rate_limit_info
                    .get("rate_limit_type")
                    .and_then(|v| v.as_str())
                    .map(String::from);
                let utilization = rate_limit_info.get("utilization").and_then(|v| v.as_f64());
                let is_using_overage = rate_limit_info
                    .get("is_using_overage")
                    .and_then(|v| v.as_bool());
                let overage_status = rate_limit_info
                    .get("overage_status")
                    .and_then(|v| v.as_str())
                    .map(String::from);
                let surpassed_threshold = rate_limit_info
                    .get("surpassed_threshold")
                    .and_then(|v| v.as_f64());

                info!(
                    component = "claude_connector",
                    event = "claude.rate_limit",
                    status = %status,
                    utilization = ?utilization,
                    rate_limit_type = ?rate_limit_type,
                    "Rate limit event received"
                );

                vec![ConnectorEvent::RateLimitEvent {
                    info: orbitdock_protocol::RateLimitInfo {
                        status,
                        resets_at,
                        rate_limit_type,
                        utilization,
                        is_using_overage,
                        overage_status,
                        surpassed_threshold,
                    },
                }]
            }

            "prompt_suggestion" => {
                let suggestion = raw
                    .get("suggestion")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();

                if suggestion.is_empty() {
                    debug!(
                        component = "claude_connector",
                        event = "claude.prompt_suggestion.empty",
                        "Prompt suggestion received with empty content"
                    );
                    vec![]
                } else {
                    debug!(
                        component = "claude_connector",
                        event = "claude.prompt_suggestion",
                        suggestion_len = suggestion.len(),
                        "Prompt suggestion received"
                    );
                    vec![ConnectorEvent::PromptSuggestion { suggestion }]
                }
            }

            "keep_alive" | "auth_status" => vec![],

            _ => {
                debug!(
                    component = "claude_connector",
                    event = "claude.stdout.unknown_type",
                    msg_type = %msg_type,
                    "Unknown stdout message type"
                );
                vec![]
            }
        };

        // Prepend TurnStarted so it fires before any message events
        let final_events = if !turn_start_event.is_empty() {
            turn_start_event.append(&mut events);
            turn_start_event
        } else {
            events
        };

        if !final_events.is_empty() && msg_type != "stream_event" {
            debug!(
                component = "claude_connector",
                event = "claude.stdout.dispatch_result",
                msg_type = %msg_type,
                event_count = final_events.len(),
                "Produced connector events"
            );
        }

        final_events
    }

    /// Handle `system` messages (init, compact_boundary, status).
    async fn handle_system_message(
        raw: &Value,
        session_id_slot: &Arc<Mutex<Option<String>>>,
        task_tool_use_map: &mut HashMap<String, String>,
        compacting_msg_id: &mut Option<String>,
        tool_rows: &mut HashMap<String, ToolRow>,
    ) -> Vec<ConnectorEvent> {
        let subtype = raw.get("subtype").and_then(|v| v.as_str()).unwrap_or("");

        match subtype {
            "init" => {
                let mut events = vec![];
                if let Some(sid) = raw.get("session_id").and_then(|v| v.as_str()) {
                    *session_id_slot.lock().await = Some(sid.to_string());
                    let model = raw.get("model").and_then(|v| v.as_str());

                    // Parse capability arrays from init message
                    let parse_string_array = |key: &str| -> Vec<String> {
                        raw.get(key)
                            .and_then(|v| v.as_array())
                            .map(|arr| {
                                arr.iter()
                                    .filter_map(|v| v.as_str().map(String::from))
                                    .collect()
                            })
                            .unwrap_or_default()
                    };
                    let slash_commands = parse_string_array("slash_commands");
                    let skills = parse_string_array("skills");
                    let tools = parse_string_array("tools");

                    info!(
                        component = "claude_connector",
                        event = "claude.init",
                        claude_session_id = %sid,
                        model = ?model,
                        slash_commands_count = slash_commands.len(),
                        skills_count = skills.len(),
                        tools_count = tools.len(),
                        "Claude session initialized via CLI"
                    );

                    if let Some(m) = model {
                        events.push(ConnectorEvent::ModelUpdated(m.to_string()));
                    }

                    // Don't read models from the mutex here — the system init
                    // message arrives on stdout before the control_response that
                    // populates the models mutex. Models are emitted separately
                    // from new() after send_initialize() completes.
                    events.push(ConnectorEvent::ClaudeInitialized {
                        slash_commands,
                        skills,
                        tools,
                        models: vec![],
                    });

                    // Parse MCP servers from init message
                    if let Some(mcp_servers) = raw.get("mcp_servers").and_then(|v| v.as_array()) {
                        let mut ready = Vec::new();
                        let mut failed = Vec::new();
                        for server in mcp_servers {
                            let name = server
                                .get("name")
                                .and_then(|v| v.as_str())
                                .unwrap_or("unknown")
                                .to_string();
                            let status_str = server
                                .get("status")
                                .and_then(|v| v.as_str())
                                .unwrap_or("unknown");

                            let mcp_status = match status_str {
                                "connected" | "ready" => {
                                    ready.push(name.clone());
                                    orbitdock_protocol::McpStartupStatus::Ready
                                }
                                "failed" | "error" => {
                                    let error = server
                                        .get("error")
                                        .and_then(|v| v.as_str())
                                        .unwrap_or("Connection failed")
                                        .to_string();
                                    failed.push(orbitdock_protocol::McpStartupFailure {
                                        server: name.clone(),
                                        error: error.clone(),
                                    });
                                    orbitdock_protocol::McpStartupStatus::Failed { error }
                                }
                                "needs-auth" | "needs_auth" => {
                                    orbitdock_protocol::McpStartupStatus::NeedsAuth
                                }
                                _ => orbitdock_protocol::McpStartupStatus::Connecting,
                            };

                            events.push(ConnectorEvent::McpStartupUpdate {
                                server: name,
                                status: mcp_status,
                            });
                        }
                        events.push(ConnectorEvent::McpStartupComplete {
                            ready,
                            failed,
                            cancelled: vec![],
                        });
                    }
                }
                events
            }
            "compact_boundary" => {
                let mut events = vec![];
                let session_id = session_id_slot.lock().await.clone().unwrap_or_default();
                // Finalize the in-progress "Compacting context…" indicator if present.
                if let Some(row_id) = compacting_msg_id.take() {
                    if let Some(mut tr) = tool_rows.remove(&row_id) {
                        tr.status = ToolStatus::Completed;
                        tr.ended_at = Some(now_iso());
                        tr.result = Some(serde_json::json!({
                            "tool_name": "CompactContext",

                            "summary": "Done",
                        }));
                        events.push(ConnectorEvent::ConversationRowUpdated {
                            row_id: row_id.clone(),
                            entry: make_entry(&session_id, ConversationRow::Tool(tr)),
                        });
                    }
                }
                events.push(ConnectorEvent::ContextCompacted);
                events
            }
            "hook_started" => {
                // Capture the hook's session_id so we can register it as a managed thread.
                // On --resume the CLI creates a new session_id for hooks, different from
                // the original. Without registering it, the hook handler creates a
                // duplicate passive session.
                if let Some(sid) = raw.get("session_id").and_then(|v| v.as_str()) {
                    info!(
                        component = "claude_connector",
                        event = "claude.hook_started",
                        hook_session_id = %sid,
                        "Hook started with session ID"
                    );
                    vec![ConnectorEvent::HookSessionId(sid.to_string())]
                } else {
                    vec![]
                }
            }
            "task_started" => {
                // Background task/subagent spawned.
                let task_id = raw
                    .get("task_id")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown-task");
                let description = raw.get("description").and_then(Value::as_str).unwrap_or("");
                let task_type = raw
                    .get("task_type")
                    .and_then(Value::as_str)
                    .unwrap_or("Agent");
                let session_id = session_id_slot.lock().await.clone().unwrap_or_default();

                if let Some(tool_use_id) = raw.get("tool_use_id").and_then(Value::as_str) {
                    task_tool_use_map.insert(tool_use_id.to_string(), task_id.to_string());
                }

                info!(
                    component = "claude_connector",
                    event = "claude.task_started",
                    task_id = %task_id,
                    task_type = %task_type,
                    tool_use_id = ?raw.get("tool_use_id").and_then(|v| v.as_str()),
                    "Background task started"
                );

                let raw_input = Some(serde_json::json!({
                    "subagent_type": task_type,
                    "description": description
                }));
                let mut tr = make_tool_row(
                    task_id.to_string(),
                    "task",
                    raw_input.as_ref(),
                    ToolStatus::Running,
                );
                tr.subtitle = if description.is_empty() {
                    None
                } else {
                    Some(description.to_string())
                };
                tool_rows.insert(task_id.to_string(), tr.clone());
                vec![ConnectorEvent::ConversationRowCreated(make_entry(
                    &session_id,
                    ConversationRow::Tool(tr),
                ))]
            }
            "task_progress" => {
                let task_id = raw
                    .get("task_id")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown-task");
                let tool_uses = raw
                    .pointer("/usage/tool_uses")
                    .and_then(Value::as_u64)
                    .unwrap_or(0);
                let duration_ms = raw
                    .pointer("/usage/duration_ms")
                    .and_then(Value::as_u64)
                    .unwrap_or(0);
                let last_tool = raw
                    .get("last_tool_name")
                    .and_then(Value::as_str)
                    .unwrap_or("");
                let description = raw.get("description").and_then(Value::as_str).unwrap_or("");

                let duration_s = duration_ms / 1000;
                let mut progress = format!("Agent running — {tool_uses} tool uses, {duration_s}s");
                if !last_tool.is_empty() {
                    progress.push_str(&format!(", last: {last_tool}"));
                }
                if !description.is_empty() {
                    progress.push_str(&format!("\n{description}"));
                }

                let session_id = session_id_slot.lock().await.clone().unwrap_or_default();
                if let Some(tr) = tool_rows.get_mut(task_id) {
                    tr.summary = Some(progress);
                    tr.duration_ms = Some(duration_ms);
                    vec![ConnectorEvent::ConversationRowUpdated {
                        row_id: task_id.to_string(),
                        entry: make_entry(&session_id, ConversationRow::Tool(tr.clone())),
                    }]
                } else {
                    vec![]
                }
            }
            "task_notification" => {
                let task_id = raw
                    .get("task_id")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown-task");
                let status_str = raw
                    .get("status")
                    .and_then(Value::as_str)
                    .unwrap_or("completed");
                let summary = raw.get("summary").and_then(Value::as_str).unwrap_or("");
                let duration_ms = raw.pointer("/usage/duration_ms").and_then(Value::as_u64);

                info!(
                    component = "claude_connector",
                    event = "claude.task_notification",
                    task_id = %task_id,
                    status = %status_str,
                    "Background task completed"
                );

                let session_id = session_id_slot.lock().await.clone().unwrap_or_default();
                if let Some(mut tr) = tool_rows.remove(task_id) {
                    tr.status = if status_str == "failed" {
                        ToolStatus::Failed
                    } else {
                        ToolStatus::Completed
                    };
                    tr.ended_at = Some(now_iso());
                    tr.summary = Some(summary.to_string());
                    tr.duration_ms = duration_ms;
                    tr.result = Some(serde_json::json!({
                        "tool_name": "task",

                        "summary": summary,
                    }));
                    vec![ConnectorEvent::ConversationRowUpdated {
                        row_id: task_id.to_string(),
                        entry: make_entry(&session_id, ConversationRow::Tool(tr)),
                    }]
                } else {
                    vec![]
                }
            }
            "status" => {
                // SDK status messages carry permission_mode and compacting state.
                // These arrive as system subtypes AND as top-level status messages.
                let mut events = vec![];

                if let Some(mode) = raw
                    .get("permissionMode")
                    .or_else(|| raw.get("permission_mode"))
                    .and_then(Value::as_str)
                {
                    info!(
                        component = "claude_connector",
                        event = "claude.permission_mode.changed",
                        mode = %mode,
                        "Permission mode changed via system status message"
                    );
                    events.push(ConnectorEvent::PermissionModeChanged {
                        mode: mode.to_string(),
                    });
                }

                // "compacting" status means context compaction is in progress.
                // Show an in-progress indicator so the user knows what's happening
                // during the ~30-90s silence before compact_boundary fires.
                if let Some(s) = raw.get("status").and_then(Value::as_str) {
                    if s == "compacting" && compacting_msg_id.is_none() {
                        let session_id = session_id_slot.lock().await.clone().unwrap_or_default();
                        let msg_id = format!("compacting-{}", uuid::Uuid::new_v4());
                        *compacting_msg_id = Some(msg_id.clone());

                        info!(
                            component = "claude_connector",
                            event = "claude.status.compacting",
                            msg_id = %msg_id,
                            "Context compaction in progress — showing indicator"
                        );

                        let tr = make_tool_row(
                            msg_id.clone(),
                            "CompactContext",
                            Some(&serde_json::json!(
                                "Compacting context to keep session within model context window…"
                            )),
                            ToolStatus::Running,
                        );
                        tool_rows.insert(msg_id.clone(), tr.clone());
                        events.push(ConnectorEvent::ConversationRowCreated(make_entry(
                            &session_id,
                            ConversationRow::Tool(tr),
                        )));
                    }
                }

                events
            }
            "hook_progress" => {
                let hook_name = raw
                    .get("hook_name")
                    .and_then(|v| v.as_str())
                    .unwrap_or("unknown");
                let hook_event = raw
                    .get("hook_event")
                    .and_then(|v| v.as_str())
                    .unwrap_or("unknown");
                debug!(
                    component = "claude_connector",
                    event = "claude.hook_progress",
                    hook_name = %hook_name,
                    hook_event = %hook_event,
                    "Hook progress event"
                );
                vec![]
            }
            "hook_response" => {
                let hook_name = raw
                    .get("hook_name")
                    .and_then(|v| v.as_str())
                    .unwrap_or("unknown");
                let outcome = raw
                    .get("outcome")
                    .and_then(|v| v.as_str())
                    .unwrap_or("unknown");
                info!(
                    component = "claude_connector",
                    event = "claude.hook_response",
                    hook_name = %hook_name,
                    outcome = %outcome,
                    "Hook response event"
                );
                vec![]
            }
            "files_persisted" => {
                let files: Vec<String> = raw
                    .get("files")
                    .and_then(|v| v.as_array())
                    .map(|arr| {
                        arr.iter()
                            .filter_map(|f| f.as_str().map(|s| s.to_string()))
                            .collect()
                    })
                    .unwrap_or_default();
                debug!(
                    component = "claude_connector",
                    event = "claude.files_persisted",
                    file_count = files.len(),
                    "Files persisted checkpoint"
                );
                vec![ConnectorEvent::FilesPersisted { files }]
            }
            _ => {
                debug!(
                    component = "claude_connector",
                    event = "claude.system.unknown_subtype",
                    subtype = %subtype,
                    "Unknown system message subtype"
                );
                vec![]
            }
        }
    }

    /// Handle `assistant` messages — extract content blocks into ConnectorEvents.
    #[allow(clippy::too_many_arguments)]
    fn handle_assistant_message(
        raw: &Value,
        session_id: &str,
        streaming_content: &mut String,
        streaming_msg_id: &mut Option<String>,
        turn_patch_diffs: &mut Vec<String>,
        last_turn_input: &mut Option<(u64, u64)>,
        cumulative_output: &mut u64,
        last_context_window: &mut u64,
        tool_rows: &mut HashMap<String, ToolRow>,
    ) -> Vec<ConnectorEvent> {
        let mut events = Vec::new();

        // Track whether streaming was active before flushing — if so, the text
        // content was already delivered via the streaming path and the final
        // assistant message's "text" blocks are duplicates.
        let had_streaming = streaming_msg_id.is_some();

        // Flush any pending streaming content
        flush_streaming(&mut events, streaming_content, streaming_msg_id, session_id);

        let message = match raw.get("message") {
            Some(m) => m,
            None => {
                debug!(
                    component = "claude_connector",
                    event = "claude.assistant.no_message_field",
                    "Assistant message missing 'message' field"
                );
                return events;
            }
        };

        let content_blocks = match message.get("content").and_then(|v| v.as_array()) {
            Some(arr) => arr,
            None => {
                debug!(
                    component = "claude_connector",
                    event = "claude.assistant.no_content_blocks",
                    "Assistant message missing 'content' array"
                );
                return events;
            }
        };

        let block_types: Vec<&str> = content_blocks
            .iter()
            .map(|b| b.get("type").and_then(|v| v.as_str()).unwrap_or("?"))
            .collect();
        debug!(
            component = "claude_connector",
            event = "claude.assistant.content_blocks",
            block_count = content_blocks.len(),
            block_types = ?block_types,
            had_streaming = had_streaming,
            "Processing assistant content blocks"
        );

        for block in content_blocks {
            let block_type = block.get("type").and_then(|v| v.as_str()).unwrap_or("");
            let id = format!(
                "claude-msg-{}-{}",
                &session_id[..8.min(session_id.len())],
                uuid::Uuid::new_v4()
            );

            match block_type {
                // Skip text blocks if streaming already delivered the content
                "text" if had_streaming => continue,
                "text" => {
                    let text = block.get("text").and_then(|v| v.as_str()).unwrap_or("");
                    let row = ConversationRow::Assistant(MessageRowContent {
                        id,
                        content: text.to_string(),
                        turn_id: None,
                        timestamp: Some(now_iso()),
                        is_streaming: false,
                        images: vec![],
                        memory_citation: None,
                    });
                    events.push(ConnectorEvent::ConversationRowCreated(make_entry(
                        session_id, row,
                    )));
                }
                "tool_use" => {
                    let tool_name = block
                        .get("name")
                        .and_then(|v| v.as_str())
                        .unwrap_or("unknown");
                    let input_value = block.get("input");
                    let tool_use_id = block.get("id").and_then(|v| v.as_str());
                    let message_id = tool_use_id.map(str::to_string).unwrap_or(id);

                    let tr = make_tool_row(
                        message_id.clone(),
                        tool_name,
                        input_value,
                        ToolStatus::Running,
                    );
                    tool_rows.insert(message_id.clone(), tr.clone());
                    events.push(ConnectorEvent::ConversationRowCreated(make_entry(
                        session_id,
                        ConversationRow::Tool(tr),
                    )));

                    // Build an aggregated per-turn patch diff stream from direct edit/write tools.
                    if let Some(payload) = input_value {
                        if let Some(diff) = Self::patch_diff_for_tool_use(Some(tool_name), payload)
                        {
                            turn_patch_diffs.push(diff);
                            events.push(ConnectorEvent::DiffUpdated(turn_patch_diffs.join("\n\n")));
                        }
                    }
                }
                "thinking" => {
                    let thinking = block.get("thinking").and_then(|v| v.as_str()).unwrap_or("");
                    let row = ConversationRow::Thinking(MessageRowContent {
                        id,
                        content: thinking.to_string(),
                        turn_id: None,
                        timestamp: Some(now_iso()),
                        is_streaming: false,
                        images: vec![],
                        memory_citation: None,
                    });
                    events.push(ConnectorEvent::ConversationRowCreated(make_entry(
                        session_id, row,
                    )));
                }
                _ => {}
            }
        }

        // Capture per-call usage from the assistant message for accurate context fill.
        if let Some(usage) = message.get("usage").and_then(Value::as_object) {
            let input = value_to_u64(usage.get("input_tokens"));
            let cached = value_to_u64(usage.get("cache_read_input_tokens"))
                + value_to_u64(usage.get("cache_creation_input_tokens"));
            *last_turn_input = Some((input, cached));
            *cumulative_output += value_to_u64(usage.get("output_tokens"));

            let live_usage = orbitdock_protocol::TokenUsage {
                input_tokens: input,
                output_tokens: *cumulative_output,
                cached_tokens: cached,
                context_window: *last_context_window,
            };
            events.push(ConnectorEvent::TokensUpdated {
                usage: live_usage,
                snapshot_kind: orbitdock_protocol::TokenUsageSnapshotKind::MixedLegacy,
            });
        }

        events
    }

    fn patch_diff_for_tool_use(tool_name: Option<&str>, payload: &Value) -> Option<String> {
        let is_patch_tool = matches!(
            tool_name,
            Some("Edit" | "Write" | "NotebookEdit" | "MultiEdit")
        );
        if !is_patch_tool {
            return None;
        }

        Self::patch_diff_for_approval(
            tool_name,
            payload,
            payload.get("file_path").and_then(|value| value.as_str()),
        )
    }

    /// Handle echoed `user` messages — extract tool results.
    fn handle_user_message(
        raw: &Value,
        session_id: &str,
        task_tool_use_map: &mut HashMap<String, String>,
        tool_rows: &mut HashMap<String, ToolRow>,
    ) -> Vec<ConnectorEvent> {
        let mut events = Vec::new();
        let message = match raw.get("message") {
            Some(m) => m,
            None => return events,
        };

        let content_blocks = match message.get("content").and_then(|v| v.as_array()) {
            Some(arr) => arr,
            None => return events,
        };

        // Extract user-facing content: text and images
        let mut text_parts: Vec<String> = Vec::new();
        let mut images: Vec<orbitdock_protocol::ImageInput> = Vec::new();

        for block in content_blocks {
            let block_type = block.get("type").and_then(|v| v.as_str()).unwrap_or("");
            match block_type {
                "text" => {
                    if let Some(text) = block.get("text").and_then(|v| v.as_str()) {
                        if !text.is_empty() {
                            text_parts.push(text.to_string());
                        }
                    }
                }
                "image" => {
                    if let Some(img) = extract_image_input(block) {
                        images.push(img);
                    }
                }
                _ => {} // tool_result handled below
            }
        }

        // Emit a User row if there's any text or images
        let user_text = text_parts.join("\n");
        if !user_text.is_empty() || !images.is_empty() {
            let msg_id = raw
                .get("message")
                .and_then(|m| m.get("id"))
                .and_then(|v| v.as_str())
                .map(String::from)
                .unwrap_or_else(|| format!("claude-user-{}", uuid::Uuid::new_v4()));

            info!(
                component = "claude_connector",
                event = "claude.user_message.row_created",
                session_id = %session_id,
                text_len = user_text.len(),
                image_count = images.len(),
                "Creating User conversation row"
            );

            events.push(ConnectorEvent::ConversationRowCreated(make_entry(
                session_id,
                ConversationRow::User(MessageRowContent {
                    id: msg_id,
                    content: user_text,
                    turn_id: None,
                    timestamp: Some(now_iso()),
                    is_streaming: false,
                    images,
                    memory_citation: None,
                }),
            )));
        }

        // Process tool_result blocks
        let has_tool_results = content_blocks
            .iter()
            .any(|b| b.get("type").and_then(|v| v.as_str()) == Some("tool_result"));

        if !has_tool_results {
            return events;
        }

        info!(
            component = "claude_connector",
            event = "claude.user_message.has_tool_results",
            session_id = %session_id,
            block_count = content_blocks.len(),
            "Processing user message with tool_result blocks"
        );

        for block in content_blocks {
            let block_type = block.get("type").and_then(|v| v.as_str()).unwrap_or("");
            if block_type != "tool_result" {
                continue;
            }

            let content = block
                .get("content")
                .map(|v| {
                    if let Some(s) = v.as_str() {
                        s.to_string()
                    } else if let Some(arr) = v.as_array() {
                        // MCP tool results return Content[] blocks — extract text
                        arr.iter()
                            .filter_map(|item| {
                                if item.get("type").and_then(|t| t.as_str()) == Some("text") {
                                    item.get("text").and_then(|t| t.as_str()).map(String::from)
                                } else {
                                    None
                                }
                            })
                            .collect::<Vec<_>>()
                            .join("\n")
                    } else {
                        v.to_string()
                    }
                })
                .unwrap_or_default();
            let is_error = block
                .get("is_error")
                .and_then(|v| v.as_bool())
                .unwrap_or(false);

            if let Some(tool_use_id) = block.get("tool_use_id").and_then(|v| v.as_str()) {
                let task_id = task_tool_use_map.remove(tool_use_id);

                info!(
                    component = "claude_connector",
                    event = "claude.tool_result.extracted",
                    session_id = %session_id,
                    tool_use_id = %tool_use_id,
                    task_id = ?task_id,
                    output_chars = content.len(),
                    is_error = is_error,
                    "Extracted tool result → ConversationRowUpdated"
                );

                // Determine the row_id: either the task_id (for background tasks)
                // or the tool_use_id (for regular tools).
                let row_id = task_id.unwrap_or_else(|| tool_use_id.to_string());

                if let Some(mut tr) = tool_rows.remove(&row_id) {
                    tr.status = if is_error {
                        ToolStatus::Failed
                    } else {
                        ToolStatus::Completed
                    };
                    let ended = now_iso();
                    // Compute duration from started_at → ended_at
                    if tr.duration_ms.is_none() {
                        if let Some(ref started) = tr.started_at {
                            if let (Some(s), Some(e)) =
                                (parse_epoch_ms(started), parse_epoch_ms(&ended))
                            {
                                if e > s {
                                    tr.duration_ms = Some(e - s);
                                }
                            }
                        }
                    }
                    tr.ended_at = Some(ended);
                    // Compute summary from tool output
                    if tr.summary.is_none() {
                        tr.summary = if is_error {
                            Some("Error".to_string())
                        } else {
                            extract_result_summary(&tr.title, &content)
                        };
                    }
                    let result_summary = tr.summary.clone();
                    tr.result = Some(serde_json::json!({
                        "tool_name": tr.title.clone(),
                        "output": content.clone(),
                        "summary": result_summary.as_deref().unwrap_or(""),
                    }));
                    // Recompute tool_display with result data
                    // invocation is now a flat serde_json::Value
                    let raw_input = if tr.invocation.is_object() {
                        Some(&tr.invocation)
                    } else {
                        None
                    };
                    tr.tool_display = Some(
                        orbitdock_protocol::conversation_contracts::compute_tool_display(
                            orbitdock_protocol::conversation_contracts::ToolDisplayInput {
                                kind: tr.kind,
                                family: tr.family,
                                status: tr.status,
                                title: &tr.title,
                                subtitle: tr.subtitle.as_deref(),
                                summary: tr.summary.as_deref(),
                                duration_ms: tr.duration_ms,
                                invocation_input: raw_input,
                                result_output: Some(&content),
                            },
                        ),
                    );
                    events.push(ConnectorEvent::ConversationRowUpdated {
                        row_id: row_id.clone(),
                        entry: make_entry(session_id, ConversationRow::Tool(tr)),
                    });
                } else {
                    // No tracked row — create a minimal completed tool row.
                    let mut tr = make_tool_row(
                        row_id.clone(),
                        "unknown",
                        None,
                        if is_error {
                            ToolStatus::Failed
                        } else {
                            ToolStatus::Completed
                        },
                    );
                    tr.ended_at = Some(now_iso());
                    tr.result = Some(serde_json::json!({
                        "tool_name": "unknown",
                        "output": content.clone(),
                    }));
                    events.push(ConnectorEvent::ConversationRowUpdated {
                        row_id,
                        entry: make_entry(session_id, ConversationRow::Tool(tr)),
                    });
                }
            } else {
                warn!(
                    component = "claude_connector",
                    event = "claude.tool_result.no_tool_use_id",
                    session_id = %session_id,
                    "tool_result block missing tool_use_id"
                );
            }
        }

        events
    }

    /// Handle `stream_event` — streaming deltas from --include-partial-messages.
    fn handle_stream_event(
        raw: &Value,
        session_id: &str,
        streaming_content: &mut String,
        streaming_msg_id: &mut Option<String>,
    ) -> Vec<ConnectorEvent> {
        let mut events = Vec::new();

        let event = match raw.get("event") {
            Some(e) => e,
            None => return events,
        };

        let event_type = event.get("type").and_then(|v| v.as_str()).unwrap_or("");

        if event_type == "content_block_delta" {
            let delta = match event.get("delta") {
                Some(d) => d,
                None => return events,
            };
            let delta_type = delta.get("type").and_then(|v| v.as_str()).unwrap_or("");

            if delta_type == "text_delta" {
                if let Some(text) = delta.get("text").and_then(|v| v.as_str()) {
                    streaming_content.push_str(text);

                    if streaming_msg_id.is_none() {
                        let msg_id = format!(
                            "claude-msg-{}-{}",
                            &session_id[..8.min(session_id.len())],
                            uuid::Uuid::new_v4()
                        );
                        let row = ConversationRow::Assistant(MessageRowContent {
                            id: msg_id.clone(),
                            content: streaming_content.clone(),
                            turn_id: None,
                            timestamp: Some(now_iso()),
                            is_streaming: true,
                            images: vec![],
                            memory_citation: None,
                        });
                        events.push(ConnectorEvent::ConversationRowCreated(make_entry(
                            session_id, row,
                        )));
                        *streaming_msg_id = Some(msg_id);
                    } else {
                        let msg_id = streaming_msg_id.clone().unwrap();
                        let row = ConversationRow::Assistant(MessageRowContent {
                            id: msg_id.clone(),
                            content: streaming_content.clone(),
                            turn_id: None,
                            timestamp: Some(now_iso()),
                            is_streaming: true,
                            images: vec![],
                            memory_citation: None,
                        });
                        events.push(ConnectorEvent::ConversationRowUpdated {
                            row_id: msg_id,
                            entry: make_entry(session_id, row),
                        });
                    }
                }
            }
        }

        events
    }

    /// Handle `tool_progress` updates for long-running tool executions.
    fn handle_tool_progress(
        raw: &Value,
        session_id: &str,
        tool_rows: &mut HashMap<String, ToolRow>,
    ) -> Vec<ConnectorEvent> {
        let Some(tool_use_id) = raw.get("tool_use_id").and_then(|v| v.as_str()) else {
            return vec![];
        };

        let tool_name = raw
            .get("tool_name")
            .and_then(|v| v.as_str())
            .unwrap_or("Tool");
        let elapsed = raw
            .get("elapsed_time_seconds")
            .and_then(|v| v.as_u64())
            .unwrap_or(0);

        if let Some(tr) = tool_rows.get_mut(tool_use_id) {
            tr.summary = Some(format!("{} running ({}s)", tool_name, elapsed));
            tr.duration_ms = Some(elapsed * 1000);
            vec![ConnectorEvent::ConversationRowUpdated {
                row_id: tool_use_id.to_string(),
                entry: make_entry(session_id, ConversationRow::Tool(tr.clone())),
            }]
        } else {
            vec![]
        }
    }

    /// Handle `result` messages — turn completed/aborted with usage.
    fn handle_result_message(
        raw: &Value,
        streaming_content: &mut String,
        streaming_msg_id: &mut Option<String>,
        last_turn_input: &mut Option<(u64, u64)>,
        cumulative_output: &mut u64,
        last_context_window: &mut u64,
        session_id: &str,
    ) -> Vec<ConnectorEvent> {
        let mut events = Vec::new();

        // Flush streaming content
        flush_streaming(&mut events, streaming_content, streaming_msg_id, session_id);

        // Build token usage. Prefer per-call input/cached from the last assistant
        // message (accurate for context fill) with cumulative output tokens.
        // Fall back to the old cumulative modelUsage extraction if no per-call data.
        let model_usage = raw.get("modelUsage").cloned();
        let usage = raw.get("usage").cloned();

        let token_usage = if let Some((input, cached)) = last_turn_input.take() {
            // Extract context_window from modelUsage (any model entry)
            let context_window = model_usage
                .as_ref()
                .and_then(Value::as_object)
                .and_then(|models| {
                    models
                        .values()
                        .find_map(|stats| stats.get("contextWindow").and_then(Value::as_u64))
                })
                .unwrap_or(1_000_000);

            Some(orbitdock_protocol::TokenUsage {
                input_tokens: input,
                output_tokens: *cumulative_output,
                cached_tokens: cached,
                context_window,
            })
        } else {
            extract_token_usage(&model_usage, &usage)
        };

        if let Some(tu) = token_usage {
            *last_context_window = tu.context_window.max(1);
            events.push(ConnectorEvent::TokensUpdated {
                usage: tu,
                snapshot_kind: orbitdock_protocol::TokenUsageSnapshotKind::MixedLegacy,
            });
        }

        let subtype = raw.get("subtype").and_then(|v| v.as_str()).unwrap_or("");
        let is_error = raw
            .get("is_error")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);

        if is_error || subtype.starts_with("error") {
            let reason = if subtype.is_empty() {
                "error".to_string()
            } else {
                subtype.to_string()
            };
            events.push(ConnectorEvent::TurnAborted { reason });
        } else {
            events.push(ConnectorEvent::TurnCompleted);
        }

        events
    }

    /// Handle `control_request` from the CLI (permission prompts, hook callbacks, MCP messages).
    async fn handle_cli_control_request(
        raw: &Value,
        pending_approvals: &Arc<Mutex<HashMap<String, PendingApproval>>>,
        stdin_tx: &mpsc::Sender<String>,
    ) -> Vec<ConnectorEvent> {
        let request = match value_field(raw, "request", "request") {
            Some(r) => r,
            None => return vec![],
        };

        let subtype = string_field(request, "subtype", "subtype")
            .or_else(|| string_field(request, "sub_type", "subType"))
            .unwrap_or_default();

        let request_id = string_field(raw, "request_id", "requestId").unwrap_or_default();

        match subtype.as_str() {
            "hook_callback" => {
                // CLI is invoking a registered hook callback.
                // We don't currently register any hooks, so respond with an empty result.
                let callback_id =
                    string_field(request, "callback_id", "callbackId").unwrap_or_default();
                info!(
                    component = "claude_connector",
                    event = "claude.control_request.hook_callback",
                    request_id = %request_id,
                    callback_id = %callback_id,
                    "Received hook_callback control request"
                );
                let response = StdinMessage::ControlResponse {
                    response: ControlResponsePayload::Success {
                        request_id,
                        response: serde_json::json!({
                            "hookResults": []
                        }),
                    },
                };
                if let Ok(json) = serde_json::to_string(&response) {
                    let _ = stdin_tx.send(json).await;
                }
                return vec![];
            }
            "mcp_message" => {
                // CLI is sending a JSON-RPC message for an SDK-hosted MCP server.
                // We don't currently host any MCP servers, so respond with an error.
                let server_name =
                    string_field(request, "server_name", "serverName").unwrap_or_default();
                info!(
                    component = "claude_connector",
                    event = "claude.control_request.mcp_message",
                    request_id = %request_id,
                    server_name = %server_name,
                    "Received mcp_message control request"
                );
                let response = StdinMessage::ControlResponse {
                    response: ControlResponsePayload::Error {
                        request_id,
                        error: format!("MCP server '{}' is not hosted by OrbitDock", server_name),
                    },
                };
                if let Ok(json) = serde_json::to_string(&response) {
                    let _ = stdin_tx.send(json).await;
                }
                return vec![];
            }
            "can_use_tool" => {
                // Permission prompt — handled below
            }
            other => {
                debug!(
                    component = "claude_connector",
                    event = "claude.control_request.unhandled",
                    subtype = %other,
                    request_id = %request_id,
                    "Unhandled CLI control request subtype"
                );
                return vec![];
            }
        }

        // --- can_use_tool handling ---
        let tool_name = string_field(request, "tool_name", "toolName");
        let input = value_field(request, "input", "input").cloned();
        let tool_use_id = string_field(request, "tool_use_id", "toolUseID")
            .or_else(|| string_field(request, "toolUseId", "toolUseId"));
        let permission_suggestions =
            value_field(request, "permission_suggestions", "permissionSuggestions")
                .cloned()
                .or_else(|| {
                    value_field(raw, "permission_suggestions", "permissionSuggestions").cloned()
                });
        let has_permission_suggestions = permission_suggestions.is_some();

        if request_id.is_empty() {
            warn!(
                component = "claude_connector",
                event = "claude.control_request.missing_request_id",
                tool_name = ?tool_name,
                tool_use_id = ?tool_use_id,
                "Claude can_use_tool request missing request_id; cannot correlate approval response"
            );
            return vec![];
        }

        // Clone suggestions for the event before moving into PendingApproval
        let suggestions_for_event = permission_suggestions.clone();

        // Store for echoing back in approve_tool response
        pending_approvals.lock().await.insert(
            request_id.clone(),
            PendingApproval {
                input: input.clone().unwrap_or(Value::Null),
                tool_use_id: tool_use_id.clone(),
                permission_suggestions,
            },
        );

        // Classify approval type
        let approval_type = match tool_name.as_deref() {
            Some("Edit" | "Write" | "NotebookEdit") => ApprovalType::Patch,
            Some("AskUserQuestion") => ApprovalType::Question,
            _ => ApprovalType::Exec,
        };

        // Extract command, file_path, diff, question from input
        let command = input
            .as_ref()
            .and_then(|i| i.get("command"))
            .and_then(|v| v.as_str())
            .map(String::from);
        let file_path = input
            .as_ref()
            .and_then(|i| i.get("file_path"))
            .and_then(|v| v.as_str())
            .map(String::from);
        let diff = input.as_ref().and_then(|payload| {
            Self::patch_diff_for_approval(tool_name.as_deref(), payload, file_path.as_deref())
        });
        let question = input
            .as_ref()
            .and_then(|i| i.get("question"))
            .and_then(|v| v.as_str())
            .map(String::from)
            .or_else(|| {
                input
                    .as_ref()
                    .and_then(|i| i.get("questions"))
                    .and_then(|v| v.as_array())
                    .and_then(|arr| arr.first())
                    .and_then(|q| q.get("question"))
                    .and_then(|v| v.as_str())
                    .map(String::from)
            });

        let plan_update = if matches!(tool_name.as_deref(), Some("ExitPlanMode")) {
            input
                .as_ref()
                .and_then(Self::plan_text_from_tool_input)
                .map(ConnectorEvent::PlanUpdated)
        } else {
            None
        };

        debug!(
            component = "claude_connector",
            event = "claude.approval_requested",
            request_id = %request_id,
            tool_name = ?tool_name,
            tool_use_id = ?tool_use_id,
            approval_type = ?approval_type,
            has_permission_suggestions,
            "CLI requesting tool approval"
        );

        let tool_input_json = input.as_ref().and_then(|i| serde_json::to_string(i).ok());
        let mut events = Vec::new();
        if let Some(plan_update) = plan_update {
            events.push(plan_update);
        }
        events.push(ConnectorEvent::ApprovalRequested {
            request_id,
            approval_type,
            tool_name: tool_name.clone(),
            tool_input: tool_input_json,
            command,
            file_path,
            diff,
            question,
            permission_reason: None,
            requested_permissions: None,
            proposed_amendment: None,
            permission_suggestions: suggestions_for_event,
            elicitation_mode: None,
            elicitation_schema: None,
            elicitation_url: None,
            elicitation_message: None,
            mcp_server_name: None,
            network_host: None,
            network_protocol: None,
        });
        events
    }

    fn patch_diff_for_approval(
        tool_name: Option<&str>,
        payload: &Value,
        fallback_file_path: Option<&str>,
    ) -> Option<String> {
        let is_patch_tool = matches!(tool_name, Some("Edit" | "Write" | "NotebookEdit"));
        if !is_patch_tool {
            return payload
                .get("new_string")
                .and_then(|value| value.as_str())
                .and_then(Self::trim_non_empty_str)
                .map(str::to_string);
        }

        let file_path = payload
            .get("file_path")
            .and_then(|value| value.as_str())
            .and_then(Self::trim_non_empty_str)
            .or_else(|| fallback_file_path.and_then(Self::trim_non_empty_str))
            .unwrap_or("file");

        let old_string = payload.get("old_string").and_then(|value| value.as_str());
        let new_string = payload.get("new_string").and_then(|value| value.as_str());

        if old_string.is_some() || new_string.is_some() {
            return Some(Self::render_patch_diff(
                file_path,
                file_path,
                old_string.unwrap_or_default(),
                new_string.unwrap_or_default(),
            ));
        }

        if let Some(content) = payload
            .get("content")
            .and_then(|value| value.as_str())
            .and_then(Self::trim_non_empty_str)
        {
            return Some(Self::render_patch_diff("/dev/null", file_path, "", content));
        }

        payload
            .get("new_string")
            .and_then(|value| value.as_str())
            .and_then(Self::trim_non_empty_str)
            .map(str::to_string)
    }

    fn plan_text_from_tool_input(payload: &Value) -> Option<String> {
        payload
            .get("plan")
            .and_then(|value| value.as_str())
            .and_then(Self::trim_non_empty_str)
            .or_else(|| {
                payload
                    .get("current_plan")
                    .and_then(|value| value.as_str())
                    .and_then(Self::trim_non_empty_str)
            })
            .map(str::to_string)
    }

    fn render_patch_diff(old_path: &str, new_path: &str, old_text: &str, new_text: &str) -> String {
        let mut lines = vec![
            format!("--- {old_path}"),
            format!("+++ {new_path}"),
            "@@".to_string(),
        ];

        lines.extend(old_text.lines().map(|line| format!("-{line}")));
        lines.extend(new_text.lines().map(|line| format!("+{line}")));

        if old_text.is_empty() && new_text.is_empty() {
            lines.push("(no textual changes provided)".to_string());
        }

        lines.join("\n")
    }

    fn trim_non_empty_str(value: &str) -> Option<&str> {
        let trimmed = value.trim();
        if trimmed.is_empty() {
            None
        } else {
            Some(trimmed)
        }
    }

    /// Handle `control_response` from CLI — resolve pending control requests.
    async fn handle_control_response(
        raw: &Value,
        pending_controls: &Arc<Mutex<HashMap<String, oneshot::Sender<Value>>>>,
    ) {
        let response = match value_field(raw, "response", "response") {
            Some(r) => r,
            None => return,
        };

        let request_id = string_field(response, "request_id", "requestId").unwrap_or_default();

        if request_id.is_empty() {
            return;
        }

        let mut pending = pending_controls.lock().await;
        if let Some(tx) = pending.remove(request_id.as_str()) {
            let _ = tx.send(response.clone());
        }
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn value_field<'a>(value: &'a Value, snake_key: &str, camel_key: &str) -> Option<&'a Value> {
    value.get(snake_key).or_else(|| value.get(camel_key))
}

fn string_field(value: &Value, snake_key: &str, camel_key: &str) -> Option<String> {
    value_field(value, snake_key, camel_key)
        .and_then(|v| v.as_str())
        .map(String::from)
}

fn now_iso() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    format!("{}.{:03}Z", ms / 1000, ms % 1000)
}

/// Parse an epoch-based timestamp ("1234567890Z" or "1234567890.123Z") to epoch milliseconds.
fn parse_epoch_ms(s: &str) -> Option<u64> {
    let stripped = s.strip_suffix('Z')?;
    if let Some((secs_str, ms_str)) = stripped.split_once('.') {
        let secs: u64 = secs_str.parse().ok()?;
        let ms: u64 = ms_str.parse().ok()?;
        Some(secs * 1000 + ms)
    } else {
        let secs: u64 = stripped.parse().ok()?;
        Some(secs * 1000)
    }
}

/// Flush accumulated streaming content into a final ConversationRowUpdated.
fn flush_streaming(
    events: &mut Vec<ConnectorEvent>,
    streaming_content: &mut String,
    streaming_msg_id: &mut Option<String>,
    session_id: &str,
) {
    if let Some(mid) = streaming_msg_id.take() {
        if !streaming_content.is_empty() {
            let row = ConversationRow::Assistant(MessageRowContent {
                id: mid.clone(),
                content: std::mem::take(streaming_content),
                turn_id: None,
                timestamp: Some(now_iso()),
                is_streaming: false,
                images: vec![],
                memory_citation: None,
            });
            events.push(ConnectorEvent::ConversationRowUpdated {
                row_id: mid,
                entry: make_entry(session_id, row),
            });
        }
    }
}

/// Format structured question answers for the Claude SDK.
///
/// The SDK's `AskUserQuestion` expects the deny message to contain the user's
/// answer. For simple single-answer cases, send the answer text directly.
/// For structured multi-question answers, format as JSON matching
/// `AskUserQuestionOutput.answers` format: `{ question_text: "value" }`.
fn format_question_answers(answers: &HashMap<String, Vec<String>>) -> String {
    // Simple case: single answer
    if answers.len() == 1 {
        if let Some(values) = answers.values().next() {
            if values.len() == 1 {
                return values[0].clone();
            }
            // Multi-select: comma-separate
            if !values.is_empty() {
                return values.join(", ");
            }
        }
    }

    // Multi-question: build JSON answers map { question_text: "comma,separated" }
    let mut answers_map = serde_json::Map::new();
    for (key, values) in answers {
        let joined = values.join(", ");
        answers_map.insert(key.clone(), Value::String(joined));
    }
    serde_json::to_string(&answers_map).unwrap_or_default()
}

/// Extract a `u64` from an optional JSON value, defaulting to 0.
fn value_to_u64(v: Option<&Value>) -> u64 {
    v.and_then(|v| v.as_u64()).unwrap_or(0)
}

/// Extract token usage from the modelUsage or usage fields in result messages.
fn extract_token_usage(
    model_usage: &Option<Value>,
    usage: &Option<Value>,
) -> Option<orbitdock_protocol::TokenUsage> {
    // Try modelUsage first (per-model breakdown, sum all models)
    if let Some(Value::Object(models)) = model_usage {
        let mut total = orbitdock_protocol::TokenUsage {
            input_tokens: 0,
            output_tokens: 0,
            cached_tokens: 0,
            context_window: 1_000_000,
        };
        for (_model_name, stats) in models {
            total.input_tokens += stats
                .get("inputTokens")
                .and_then(|v| v.as_u64())
                .unwrap_or(0);
            total.output_tokens += stats
                .get("outputTokens")
                .and_then(|v| v.as_u64())
                .unwrap_or(0);
            total.cached_tokens += stats
                .get("cacheReadInputTokens")
                .and_then(|v| v.as_u64())
                .unwrap_or(0)
                + stats
                    .get("cacheCreationInputTokens")
                    .and_then(|v| v.as_u64())
                    .unwrap_or(0);
            if let Some(cw) = stats.get("contextWindow").and_then(|v| v.as_u64()) {
                total.context_window = cw;
            }
        }
        if total.input_tokens > 0 || total.output_tokens > 0 {
            return Some(total);
        }
    }

    // Fallback to flat usage object
    if let Some(u) = usage {
        let input = u.get("input_tokens").and_then(|v| v.as_u64()).unwrap_or(0);
        let output = u.get("output_tokens").and_then(|v| v.as_u64()).unwrap_or(0);
        let cached = u
            .get("cache_read_input_tokens")
            .and_then(|v| v.as_u64())
            .unwrap_or(0)
            + u.get("cache_creation_input_tokens")
                .and_then(|v| v.as_u64())
                .unwrap_or(0);
        if input > 0 || output > 0 {
            return Some(orbitdock_protocol::TokenUsage {
                input_tokens: input,
                output_tokens: output,
                cached_tokens: cached,
                context_window: 1_000_000,
            });
        }
    }

    None
}

/// Resolve the claude binary path.
/// 1. CLAUDE_BIN env var
/// 2. ~/.claude/local/claude
/// 3. Search PATH via `which`
fn resolve_claude_binary() -> Result<String, ConnectorError> {
    // 1. Env var override
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

    // 2. Well-known location
    if let Ok(home) = std::env::var("HOME") {
        let local_path = format!("{}/.claude/local/claude", home);
        if std::path::Path::new(&local_path).exists() {
            return Ok(local_path);
        }
    }

    // 3. Search PATH
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

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::sync::Arc;

    use serde_json::{json, Value};
    use tokio::sync::Mutex;

    use super::{
        parse_data_uri_base64, transform_image, ClaudeConnector, ImageSource, PendingApproval,
        UserContentBlock,
    };
    use crate::ConnectorEvent;

    #[test]
    fn parse_data_uri_base64_extracts_media_type_and_payload() {
        let uri = "data:image/png;base64,aGVs\nbG8=";
        let parsed = parse_data_uri_base64(uri).expect("expected valid data uri");
        assert_eq!(parsed.0, "image/png");
        assert_eq!(parsed.1, "aGVsbG8=");
    }

    #[test]
    fn transform_image_converts_data_uri_url_to_base64_source() {
        let input = orbitdock_protocol::ImageInput {
            input_type: "url".to_string(),
            value: "data:image/png;base64,aGVsbG8=".to_string(),
            ..Default::default()
        };
        let block = transform_image(&input).expect("transform should succeed");
        match block {
            UserContentBlock::Image {
                source: ImageSource::Base64 { media_type, data },
            } => {
                assert_eq!(media_type, "image/png");
                assert_eq!(data, "aGVsbG8=");
            }
            other => panic!("expected base64 image source, got {:?}", other),
        }
    }

    #[test]
    fn transform_image_keeps_http_url_as_url_source() {
        let input = orbitdock_protocol::ImageInput {
            input_type: "url".to_string(),
            value: "https://example.com/image.png".to_string(),
            ..Default::default()
        };
        let block = transform_image(&input).expect("transform should succeed");
        match block {
            UserContentBlock::Image {
                source: ImageSource::Url { url },
            } => assert_eq!(url, "https://example.com/image.png"),
            other => panic!("expected url image source, got {:?}", other),
        }
    }

    #[tokio::test]
    async fn handle_cli_control_request_accepts_camel_case_permission_fields() {
        let pending_approvals: Arc<Mutex<HashMap<String, PendingApproval>>> =
            Arc::new(Mutex::new(HashMap::new()));
        let permission_suggestions = json!([
            {
                "type": "addRules",
                "behavior": "allow",
                "destination": "session",
                "rules": [{ "toolName": "Bash", "ruleContent": "npm test" }]
            }
        ]);

        let raw = json!({
            "type": "control_request",
            "requestId": "req-camel-1",
            "request": {
                "subtype": "can_use_tool",
                "toolName": "Bash",
                "toolUseID": "toolu-camel-1",
                "input": { "command": "npm test" },
                "permissionSuggestions": permission_suggestions
            }
        });

        let (stdin_tx, _stdin_rx) = tokio::sync::mpsc::channel::<String>(16);
        let events =
            ClaudeConnector::handle_cli_control_request(&raw, &pending_approvals, &stdin_tx).await;
        assert_eq!(events.len(), 1);
        match &events[0] {
            ConnectorEvent::ApprovalRequested {
                request_id,
                tool_name,
                command,
                ..
            } => {
                assert_eq!(request_id, "req-camel-1");
                assert_eq!(tool_name.as_deref(), Some("Bash"));
                assert_eq!(command.as_deref(), Some("npm test"));
            }
            other => panic!("expected ApprovalRequested event, got {:?}", other),
        }

        let pending = pending_approvals.lock().await;
        let stored = pending
            .get("req-camel-1")
            .expect("pending approval should be stored");
        assert_eq!(stored.tool_use_id.as_deref(), Some("toolu-camel-1"));
        assert_eq!(
            stored.permission_suggestions,
            Some(raw["request"]["permissionSuggestions"].clone())
        );
    }

    #[tokio::test]
    async fn handle_cli_control_request_uses_top_level_permission_suggestions_fallback() {
        let pending_approvals: Arc<Mutex<HashMap<String, PendingApproval>>> =
            Arc::new(Mutex::new(HashMap::new()));
        let permission_suggestions: Value = json!([
            {
                "type": "addRules",
                "behavior": "allow",
                "destination": "session",
                "rules": [{ "toolName": "Bash", "ruleContent": "git status" }]
            }
        ]);

        let raw = json!({
            "type": "control_request",
            "request_id": "req-top-level-1",
            "permissionSuggestions": permission_suggestions,
            "request": {
                "subtype": "can_use_tool",
                "tool_name": "Bash",
                "input": { "command": "git status" }
            }
        });

        let (stdin_tx, _stdin_rx) = tokio::sync::mpsc::channel::<String>(16);
        let events =
            ClaudeConnector::handle_cli_control_request(&raw, &pending_approvals, &stdin_tx).await;
        assert_eq!(events.len(), 1);

        let pending = pending_approvals.lock().await;
        let stored = pending
            .get("req-top-level-1")
            .expect("pending approval should be stored");
        assert_eq!(
            stored.permission_suggestions,
            Some(raw["permissionSuggestions"].clone())
        );
    }

    #[tokio::test]
    async fn handle_cli_control_request_emits_plan_update_for_exit_plan_mode() {
        let pending_approvals: Arc<Mutex<HashMap<String, PendingApproval>>> =
            Arc::new(Mutex::new(HashMap::new()));

        let raw = json!({
            "type": "control_request",
            "request_id": "req-plan-1",
            "request": {
                "subtype": "can_use_tool",
                "tool_name": "ExitPlanMode",
                "tool_use_id": "toolu-plan-1",
                "input": {
                    "plan": "# Phase 5\n- Simplify toolbar ordering UX"
                }
            }
        });

        let (stdin_tx, _stdin_rx) = tokio::sync::mpsc::channel::<String>(16);
        let events =
            ClaudeConnector::handle_cli_control_request(&raw, &pending_approvals, &stdin_tx).await;
        assert_eq!(events.len(), 2);

        match &events[0] {
            ConnectorEvent::PlanUpdated(plan) => {
                assert_eq!(plan, "# Phase 5\n- Simplify toolbar ordering UX");
            }
            other => panic!("expected PlanUpdated event, got {:?}", other),
        }

        match &events[1] {
            ConnectorEvent::ApprovalRequested {
                request_id,
                tool_name,
                ..
            } => {
                assert_eq!(request_id, "req-plan-1");
                assert_eq!(tool_name.as_deref(), Some("ExitPlanMode"));
            }
            other => panic!("expected ApprovalRequested event, got {:?}", other),
        }
    }

    #[tokio::test]
    async fn handle_cli_control_request_rejects_missing_request_id() {
        let pending_approvals: Arc<Mutex<HashMap<String, PendingApproval>>> =
            Arc::new(Mutex::new(HashMap::new()));

        let raw = json!({
            "type": "control_request",
            "request": {
                "subtype": "can_use_tool",
                "tool_name": "Bash",
                "input": { "command": "pwd" }
            }
        });

        let (stdin_tx, _stdin_rx) = tokio::sync::mpsc::channel::<String>(16);
        let events =
            ClaudeConnector::handle_cli_control_request(&raw, &pending_approvals, &stdin_tx).await;
        assert!(events.is_empty(), "missing request id should be ignored");
        assert!(pending_approvals.lock().await.is_empty());
    }

    #[test]
    fn handle_assistant_message_emits_diff_for_edit_tool_use() {
        let raw = json!({
            "type": "assistant",
            "message": {
                "content": [
                    {
                        "type": "tool_use",
                        "id": "toolu-edit-1",
                        "name": "Edit",
                        "input": {
                            "file_path": "src/main.rs",
                            "old_string": "old value",
                            "new_string": "new value"
                        }
                    }
                ]
            }
        });

        let mut streaming_content = String::new();
        let mut streaming_msg_id = None;
        let mut turn_patch_diffs = Vec::new();
        let mut last_turn_input = None;
        let mut cumulative_output = 0;
        let mut last_context_window = 200_000;
        let mut tool_rows = HashMap::new();

        let events = ClaudeConnector::handle_assistant_message(
            &raw,
            "sess-1",
            &mut streaming_content,
            &mut streaming_msg_id,
            &mut turn_patch_diffs,
            &mut last_turn_input,
            &mut cumulative_output,
            &mut last_context_window,
            &mut tool_rows,
        );

        let has_diff = events.iter().any(|event| {
            matches!(
                event,
                ConnectorEvent::DiffUpdated(diff)
                    if diff.contains("--- src/main.rs")
                        && diff.contains("+++ src/main.rs")
                        && diff.contains("-old value")
                        && diff.contains("+new value")
            )
        });
        assert!(has_diff, "expected DiffUpdated with patch-like content");
    }

    #[test]
    fn handle_assistant_message_aggregates_patch_diffs_across_events() {
        let raw_edit = json!({
            "type": "assistant",
            "message": {
                "content": [
                    {
                        "type": "tool_use",
                        "id": "toolu-edit-1",
                        "name": "Edit",
                        "input": {
                            "file_path": "src/a.txt",
                            "old_string": "before",
                            "new_string": "after"
                        }
                    }
                ]
            }
        });
        let raw_write = json!({
            "type": "assistant",
            "message": {
                "content": [
                    {
                        "type": "tool_use",
                        "id": "toolu-write-1",
                        "name": "Write",
                        "input": {
                            "file_path": "src/b.txt",
                            "content": "hello"
                        }
                    }
                ]
            }
        });

        let mut streaming_content = String::new();
        let mut streaming_msg_id = None;
        let mut turn_patch_diffs = Vec::new();
        let mut last_turn_input = None;
        let mut cumulative_output = 0;
        let mut last_context_window = 200_000;
        let mut tool_rows = HashMap::new();

        let _ = ClaudeConnector::handle_assistant_message(
            &raw_edit,
            "sess-1",
            &mut streaming_content,
            &mut streaming_msg_id,
            &mut turn_patch_diffs,
            &mut last_turn_input,
            &mut cumulative_output,
            &mut last_context_window,
            &mut tool_rows,
        );

        let second_events = ClaudeConnector::handle_assistant_message(
            &raw_write,
            "sess-1",
            &mut streaming_content,
            &mut streaming_msg_id,
            &mut turn_patch_diffs,
            &mut last_turn_input,
            &mut cumulative_output,
            &mut last_context_window,
            &mut tool_rows,
        );

        let aggregated = second_events.iter().find_map(|event| {
            if let ConnectorEvent::DiffUpdated(diff) = event {
                Some(diff.as_str())
            } else {
                None
            }
        });
        let diff = aggregated.expect("expected aggregated diff event");
        assert!(
            diff.contains("--- src/a.txt")
                && diff.contains("--- /dev/null")
                && diff.contains("+++ src/b.txt"),
            "expected combined diff for both edits"
        );
    }
}
