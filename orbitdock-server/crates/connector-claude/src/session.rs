//! Claude session management — struct, action enum, and action dispatch.
//!
//! The event loop (start_event_loop / handle_event_direct) lives in the server
//! crate because it depends on SessionHandle, PersistCommand, SessionActorHandle,
//! and SessionRegistry.

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
        answer: String,
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
            Self::AnswerQuestion { request_id, answer } => f
                .debug_struct("AnswerQuestion")
                .field("request_id", request_id)
                .field("answer_len", &answer.len())
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
            ClaudeAction::AnswerQuestion { request_id, answer } => {
                connector.answer_question(&request_id, &answer).await?;
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
                // Claude SDK has no native steer_input — interrupt the active
                // turn and resend the guidance as a new user message.
                connector.interrupt().await?;
                connector
                    .send_message(&content, None, None, &images)
                    .await?;
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
