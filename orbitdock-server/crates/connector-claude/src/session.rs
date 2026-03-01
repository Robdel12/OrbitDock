//! Claude session management — struct, action enum, and action dispatch.
//!
//! The event loop (start_event_loop / handle_event_direct) lives in the server
//! crate because it depends on SessionHandle, PersistCommand, SessionActorHandle,
//! and SessionRegistry.

use std::collections::HashMap;

use orbitdock_connector_core::ConnectorError;
use orbitdock_protocol::ProviderSessionId;

use crate::ClaudeConnector;

/// Actions that can be sent to a Claude session
#[allow(dead_code)]
pub enum ClaudeAction {
    SendMessage {
        content: String,
        model: Option<String>,
        effort: Option<String>,
        images: Vec<orbitdock_protocol::ImageInput>,
    },
    Interrupt,
    ApproveTool {
        request_id: String,
        decision: String,
        message: Option<String>,
        interrupt: Option<bool>,
        updated_input: Option<serde_json::Value>,
    },
    AnswerQuestion {
        request_id: String,
        answers: HashMap<String, Vec<String>>,
    },
    Compact,
    Undo,
    Resume {
        session_id: String,
    },
    Fork {
        session_id: Option<String>,
    },
    SetModel {
        model: String,
    },
    SetMaxThinking {
        tokens: u64,
    },
    SetPermissionMode {
        mode: String,
    },
    SteerTurn {
        content: String,
        message_id: String,
        images: Vec<orbitdock_protocol::ImageInput>,
    },
    RewindFiles {
        user_message_id: String,
    },
    StopTask {
        task_id: String,
    },
    ListMcpTools,
    RefreshMcpServer {
        server_name: String,
    },
    McpToggle {
        server_name: String,
        enabled: bool,
    },
    McpAuthenticate {
        server_name: String,
    },
    McpClearAuth {
        server_name: String,
    },
    McpSetServers {
        servers: serde_json::Value,
    },
    ApplyFlagSettings {
        settings: serde_json::Value,
    },
    EndSession,
}

impl std::fmt::Debug for ClaudeAction {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::SendMessage {
                content,
                model,
                effort,
                images,
            } => f
                .debug_struct("SendMessage")
                .field("content_len", &content.len())
                .field("model", model)
                .field("effort", effort)
                .field("images_count", &images.len())
                .finish(),
            Self::Interrupt => write!(f, "Interrupt"),
            Self::ApproveTool {
                request_id,
                decision,
                ..
            } => f
                .debug_struct("ApproveTool")
                .field("request_id", request_id)
                .field("decision", decision)
                .finish(),
            Self::AnswerQuestion {
                request_id,
                answers,
            } => f
                .debug_struct("AnswerQuestion")
                .field("request_id", request_id)
                .field("answers_count", &answers.len())
                .finish(),
            Self::Compact => write!(f, "Compact"),
            Self::Undo => write!(f, "Undo"),
            Self::Resume { session_id } => f
                .debug_struct("Resume")
                .field("session_id", session_id)
                .finish(),
            Self::Fork { session_id } => f
                .debug_struct("Fork")
                .field("session_id", session_id)
                .finish(),
            Self::SetModel { model } => f.debug_struct("SetModel").field("model", model).finish(),
            Self::SetMaxThinking { tokens } => f
                .debug_struct("SetMaxThinking")
                .field("tokens", tokens)
                .finish(),
            Self::SetPermissionMode { mode } => f
                .debug_struct("SetPermissionMode")
                .field("mode", mode)
                .finish(),
            Self::SteerTurn {
                content,
                message_id,
                images,
            } => f
                .debug_struct("SteerTurn")
                .field("content_len", &content.len())
                .field("message_id", message_id)
                .field("images_count", &images.len())
                .finish(),
            Self::RewindFiles { user_message_id } => f
                .debug_struct("RewindFiles")
                .field("user_message_id", user_message_id)
                .finish(),
            Self::StopTask { task_id } => f
                .debug_struct("StopTask")
                .field("task_id", task_id)
                .finish(),
            Self::ListMcpTools => write!(f, "ListMcpTools"),
            Self::RefreshMcpServer { server_name } => f
                .debug_struct("RefreshMcpServer")
                .field("server_name", server_name)
                .finish(),
            Self::McpToggle {
                server_name,
                enabled,
            } => f
                .debug_struct("McpToggle")
                .field("server_name", server_name)
                .field("enabled", enabled)
                .finish(),
            Self::McpAuthenticate { server_name } => f
                .debug_struct("McpAuthenticate")
                .field("server_name", server_name)
                .finish(),
            Self::McpClearAuth { server_name } => f
                .debug_struct("McpClearAuth")
                .field("server_name", server_name)
                .finish(),
            Self::McpSetServers { .. } => write!(f, "McpSetServers"),
            Self::ApplyFlagSettings { .. } => write!(f, "ApplyFlagSettings"),
            Self::EndSession => write!(f, "EndSession"),
        }
    }
}

/// Manages a Claude session with its connector
pub struct ClaudeSession {
    pub session_id: String,
    pub connector: ClaudeConnector,
}

impl ClaudeSession {
    /// Create a new Claude session by spawning a CLI subprocess.
    /// If `resume_id` is provided, the CLI will resume that session.
    /// Accepts `ProviderSessionId` to prevent accidentally passing an OrbitDock ID.
    #[allow(clippy::too_many_arguments)]
    pub async fn new(
        session_id: String,
        cwd: &str,
        model: Option<&str>,
        resume_id: Option<&ProviderSessionId>,
        permission_mode: Option<&str>,
        allowed_tools: &[String],
        disallowed_tools: &[String],
        effort: Option<&str>,
    ) -> Result<Self, ConnectorError> {
        let connector = ClaudeConnector::new(
            cwd,
            model,
            resume_id.map(|id| id.as_str()),
            permission_mode,
            allowed_tools,
            disallowed_tools,
            effort,
        )
        .await?;
        Ok(Self {
            session_id,
            connector,
        })
    }

    /// Handle an action from the WebSocket.
    pub async fn handle_action(
        connector: &ClaudeConnector,
        action: ClaudeAction,
    ) -> Result<(), ConnectorError> {
        match action {
            ClaudeAction::SendMessage {
                content,
                model,
                effort,
                images,
            } => {
                connector
                    .send_message(&content, model.as_deref(), effort.as_deref(), &images)
                    .await?;
            }
            ClaudeAction::Interrupt => {
                connector.interrupt().await?;
            }
            ClaudeAction::ApproveTool {
                request_id,
                decision,
                message,
                interrupt,
                updated_input,
            } => {
                connector
                    .approve_tool(
                        &request_id,
                        &decision,
                        message.as_deref(),
                        interrupt,
                        updated_input.as_ref(),
                    )
                    .await?;
            }
            ClaudeAction::AnswerQuestion {
                request_id,
                answers,
            } => {
                connector.answer_question(&request_id, &answers).await?;
            }
            ClaudeAction::Compact => {
                // Send /compact as a user message — the CLI handles it as a slash command.
                connector.send_message("/compact", None, None, &[]).await?;
            }
            ClaudeAction::Undo => {
                // Send /undo as a slash command
                connector.send_message("/undo", None, None, &[]).await?;
            }
            ClaudeAction::Resume { .. } => {
                // Resume is handled at spawn time via --resume flag.
                tracing::warn!(
                    component = "claude_connector",
                    event = "claude.action.resume_noop",
                    "Resume action received but resume is handled at spawn time"
                );
            }
            ClaudeAction::Fork { .. } => {
                // Fork is handled at spawn time via --resume --fork-session flags.
                tracing::warn!(
                    component = "claude_connector",
                    event = "claude.action.fork_noop",
                    "Fork action received but fork is handled at spawn time"
                );
            }
            ClaudeAction::SetModel { model } => {
                connector.set_model(&model).await?;
            }
            ClaudeAction::SetMaxThinking { tokens } => {
                connector.set_max_thinking(tokens).await?;
            }
            ClaudeAction::SetPermissionMode { mode } => {
                connector.set_permission_mode(&mode).await?;
            }
            ClaudeAction::SteerTurn {
                content, images, ..
            } => {
                // Write directly to stdin — CLI queues mid-turn messages naturally.
                // No interrupt needed: the SDK's streamInput just enqueues user
                // messages and the CLI processes them when the current turn yields.
                connector
                    .send_message(&content, None, None, &images)
                    .await?;
            }
            ClaudeAction::RewindFiles { user_message_id } => {
                connector.rewind_files(&user_message_id, false).await?;
            }
            ClaudeAction::StopTask { task_id } => {
                connector.stop_task(&task_id).await?;
            }
            ClaudeAction::ListMcpTools => {
                let _ = connector.mcp_status().await;
            }
            ClaudeAction::RefreshMcpServer { server_name } => {
                connector.mcp_reconnect(&server_name).await?;
            }
            ClaudeAction::McpToggle {
                server_name,
                enabled,
            } => {
                connector.mcp_toggle(&server_name, enabled).await?;
            }
            ClaudeAction::McpAuthenticate { server_name } => {
                connector.mcp_authenticate(&server_name).await?;
            }
            ClaudeAction::McpClearAuth { server_name } => {
                connector.mcp_clear_auth(&server_name).await?;
            }
            ClaudeAction::McpSetServers { servers } => {
                let _ = connector.mcp_set_servers(servers).await;
            }
            ClaudeAction::ApplyFlagSettings { settings } => {
                connector.apply_flag_settings(settings).await?;
            }
            ClaudeAction::EndSession => {
                connector.shutdown().await?;
            }
        }
        Ok(())
    }
}

/// Returns true if the shadow session should be cleaned up at runtime.
/// Guards against accidentally deleting the owning direct session when
/// the SDK session id is identical to the OrbitDock session id.
pub fn should_remove_shadow_runtime_session(
    owning_session_id: &str,
    observed_sdk_session_id: &str,
) -> bool {
    owning_session_id != observed_sdk_session_id
}

#[cfg(test)]
mod tests {
    use super::should_remove_shadow_runtime_session;

    #[test]
    fn shadow_cleanup_skips_owning_session_id() {
        assert!(!should_remove_shadow_runtime_session(
            "owning-session",
            "owning-session"
        ));
    }

    #[test]
    fn shadow_cleanup_allows_distinct_shadow_session_id() {
        assert!(should_remove_shadow_runtime_session(
            "owning-session",
            "hook-shadow-session"
        ));
    }
}
