//! Codex session management — struct, action enum, and action dispatch.
//!
//! The event loop (start_event_loop / handle_event_direct) lives in the server
//! crate because it depends on SessionHandle, PersistCommand, SessionActorHandle,
//! and SessionRegistry.

use std::collections::HashMap;

use orbitdock_connector_core::ConnectorError;
use serde_json::Value;
use tokio::sync::oneshot;

use crate::{CodexConnector, CodexControlPlane, UpdateConfigOptions};

/// Actions that can be sent to a Codex session
pub enum CodexAction {
    SendMessage {
        content: String,
        model: Option<String>,
        effort: Option<String>,
        skills: Vec<orbitdock_protocol::SkillInput>,
        images: Vec<orbitdock_protocol::ImageInput>,
        mentions: Vec<orbitdock_protocol::MentionInput>,
    },
    SteerTurn {
        content: String,
        message_id: String,
        images: Vec<orbitdock_protocol::ImageInput>,
        mentions: Vec<orbitdock_protocol::MentionInput>,
    },
    Interrupt,
    ListSkills {
        cwds: Vec<String>,
        force_reload: bool,
    },
    ListRemoteSkills,
    DownloadRemoteSkill {
        hazelnut_id: String,
    },
    ApproveExec {
        request_id: String,
        decision: String,
        proposed_amendment: Option<Vec<String>>,
    },
    ApprovePatch {
        request_id: String,
        decision: String,
    },
    AnswerQuestion {
        request_id: String,
        answers: HashMap<String, Vec<String>>,
    },
    RequestPermissionsResponse {
        request_id: String,
        permissions: Value,
        scope: orbitdock_protocol::PermissionGrantScope,
    },
    UpdateConfig {
        approval_policy: Option<String>,
        sandbox_mode: Option<String>,
        permission_mode: Option<String>,
        collaboration_mode: Option<String>,
        multi_agent: Option<bool>,
        personality: Option<String>,
        service_tier: Option<String>,
        developer_instructions: Option<String>,
        model: Option<String>,
        effort: Option<String>,
    },
    SetThreadName {
        name: String,
    },
    ListMcpTools,
    RefreshMcpServers,
    Compact,
    Undo,
    ThreadRollback {
        num_turns: u32,
    },
    EndSession,
    ForkSession {
        source_session_id: String,
        nth_user_message: Option<u32>,
        model: Option<String>,
        approval_policy: Option<String>,
        sandbox_mode: Option<String>,
        cwd: Option<String>,
        reply_tx: oneshot::Sender<Result<(CodexConnector, String), ConnectorError>>,
    },
}

impl std::fmt::Debug for CodexAction {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::SendMessage {
                content,
                model,
                effort,
                skills,
                images,
                mentions,
            } => f
                .debug_struct("SendMessage")
                .field("content_len", &content.len())
                .field("model", model)
                .field("effort", effort)
                .field("skills_count", &skills.len())
                .field("images_count", &images.len())
                .field("mentions_count", &mentions.len())
                .finish(),
            Self::SteerTurn {
                content,
                message_id,
                images,
                mentions,
            } => f
                .debug_struct("SteerTurn")
                .field("content_len", &content.len())
                .field("message_id", message_id)
                .field("images_count", &images.len())
                .field("mentions_count", &mentions.len())
                .finish(),
            Self::Interrupt => write!(f, "Interrupt"),
            Self::ListSkills { cwds, force_reload } => f
                .debug_struct("ListSkills")
                .field("cwds", cwds)
                .field("force_reload", force_reload)
                .finish(),
            Self::ListRemoteSkills => write!(f, "ListRemoteSkills"),
            Self::DownloadRemoteSkill { hazelnut_id } => f
                .debug_struct("DownloadRemoteSkill")
                .field("hazelnut_id", hazelnut_id)
                .finish(),
            Self::ApproveExec {
                request_id,
                decision,
                ..
            } => f
                .debug_struct("ApproveExec")
                .field("request_id", request_id)
                .field("decision", decision)
                .finish(),
            Self::ApprovePatch {
                request_id,
                decision,
            } => f
                .debug_struct("ApprovePatch")
                .field("request_id", request_id)
                .field("decision", decision)
                .finish(),
            Self::AnswerQuestion { request_id, .. } => f
                .debug_struct("AnswerQuestion")
                .field("request_id", request_id)
                .finish(),
            Self::RequestPermissionsResponse {
                request_id, scope, ..
            } => f
                .debug_struct("RequestPermissionsResponse")
                .field("request_id", request_id)
                .field("scope", scope)
                .finish(),
            Self::UpdateConfig {
                approval_policy,
                sandbox_mode,
                permission_mode,
                collaboration_mode,
                multi_agent,
                personality,
                service_tier,
                developer_instructions,
                model,
                effort,
            } => f
                .debug_struct("UpdateConfig")
                .field("approval_policy", approval_policy)
                .field("sandbox_mode", sandbox_mode)
                .field("permission_mode", permission_mode)
                .field("collaboration_mode", collaboration_mode)
                .field("multi_agent", multi_agent)
                .field("personality", personality)
                .field("service_tier", service_tier)
                .field(
                    "developer_instructions",
                    &developer_instructions.as_ref().map(|_| "[set]"),
                )
                .field("model", model)
                .field("effort", effort)
                .finish(),
            Self::SetThreadName { name } => {
                f.debug_struct("SetThreadName").field("name", name).finish()
            }
            Self::ListMcpTools => write!(f, "ListMcpTools"),
            Self::RefreshMcpServers => write!(f, "RefreshMcpServers"),
            Self::Compact => write!(f, "Compact"),
            Self::Undo => write!(f, "Undo"),
            Self::ThreadRollback { num_turns } => f
                .debug_struct("ThreadRollback")
                .field("num_turns", num_turns)
                .finish(),
            Self::EndSession => write!(f, "EndSession"),
            Self::ForkSession {
                source_session_id,
                nth_user_message,
                model,
                ..
            } => f
                .debug_struct("ForkSession")
                .field("source_session_id", source_session_id)
                .field("nth_user_message", nth_user_message)
                .field("model", model)
                .finish(),
        }
    }
}

/// Manages a Codex session with its connector
pub struct CodexSession {
    pub session_id: String,
    pub connector: CodexConnector,
}

impl CodexSession {
    /// Create a new Codex session
    pub async fn new(
        session_id: String,
        cwd: &str,
        model: Option<&str>,
        approval_policy: Option<&str>,
        sandbox_mode: Option<&str>,
    ) -> Result<Self, ConnectorError> {
        let connector = CodexConnector::new(cwd, model, approval_policy, sandbox_mode).await?;

        Ok(Self {
            session_id,
            connector,
        })
    }

    /// Create a new Codex session with explicit control-plane settings.
    pub async fn new_with_control_plane(
        session_id: String,
        cwd: &str,
        model: Option<&str>,
        approval_policy: Option<&str>,
        sandbox_mode: Option<&str>,
        control_plane: CodexControlPlane,
    ) -> Result<Self, ConnectorError> {
        Self::new_with_control_plane_and_tools(
            session_id,
            cwd,
            model,
            approval_policy,
            sandbox_mode,
            control_plane,
            Vec::new(),
        )
        .await
    }

    /// Create a new Codex session with control-plane settings and dynamic tools.
    ///
    /// Accepts `Vec<serde_json::Value>` for cross-crate flexibility — converts to
    /// `DynamicToolSpec` internally.
    pub async fn new_with_control_plane_and_tools(
        session_id: String,
        cwd: &str,
        model: Option<&str>,
        approval_policy: Option<&str>,
        sandbox_mode: Option<&str>,
        control_plane: CodexControlPlane,
        dynamic_tools_json: Vec<serde_json::Value>,
    ) -> Result<Self, ConnectorError> {
        let dynamic_tools: Vec<codex_protocol::dynamic_tools::DynamicToolSpec> = dynamic_tools_json
            .into_iter()
            .filter_map(|v| serde_json::from_value(v).ok())
            .collect();

        let connector = CodexConnector::new_with_control_plane_and_tools(
            cwd,
            model,
            approval_policy,
            sandbox_mode,
            control_plane,
            dynamic_tools,
        )
        .await?;

        Ok(Self {
            session_id,
            connector,
        })
    }

    /// Resume an existing Codex session from its rollout file (preserves conversation history)
    pub async fn resume(
        session_id: String,
        cwd: &str,
        thread_id: &str,
        model: Option<&str>,
        approval_policy: Option<&str>,
        sandbox_mode: Option<&str>,
    ) -> Result<Self, ConnectorError> {
        let connector =
            CodexConnector::resume(cwd, thread_id, model, approval_policy, sandbox_mode).await?;

        Ok(Self {
            session_id,
            connector,
        })
    }

    /// Resume an existing Codex session with explicit control-plane settings.
    pub async fn resume_with_control_plane(
        session_id: String,
        cwd: &str,
        thread_id: &str,
        model: Option<&str>,
        approval_policy: Option<&str>,
        sandbox_mode: Option<&str>,
        control_plane: CodexControlPlane,
    ) -> Result<Self, ConnectorError> {
        let connector = CodexConnector::resume_with_control_plane(
            cwd,
            thread_id,
            model,
            approval_policy,
            sandbox_mode,
            control_plane,
        )
        .await?;

        Ok(Self {
            session_id,
            connector,
        })
    }

    /// Get the codex-core thread ID (used to link with rollout files)
    pub fn thread_id(&self) -> &str {
        self.connector.thread_id()
    }

    /// Handle an action from the WebSocket
    pub async fn handle_action(
        connector: &mut CodexConnector,
        action: CodexAction,
    ) -> Result<(), ConnectorError> {
        match action {
            CodexAction::SendMessage {
                content,
                model,
                effort,
                skills,
                images,
                mentions,
            } => {
                connector
                    .send_message(
                        &content,
                        model.as_deref(),
                        effort.as_deref(),
                        &skills,
                        &images,
                        &mentions,
                    )
                    .await?;
            }
            CodexAction::SteerTurn { .. } => {
                unreachable!("SteerTurn should be handled in the main event loop");
            }
            CodexAction::Interrupt => {
                connector.interrupt().await?;
            }
            CodexAction::ListSkills { cwds, force_reload } => {
                connector.list_skills(cwds, force_reload).await?;
            }
            CodexAction::ListRemoteSkills => {
                connector.list_remote_skills().await?;
            }
            CodexAction::DownloadRemoteSkill { hazelnut_id } => {
                connector.download_remote_skill(&hazelnut_id).await?;
            }
            CodexAction::ApproveExec {
                request_id,
                decision,
                proposed_amendment,
            } => {
                connector
                    .approve_exec(&request_id, &decision, proposed_amendment)
                    .await?;
            }
            CodexAction::ApprovePatch {
                request_id,
                decision,
            } => {
                connector.approve_patch(&request_id, &decision).await?;
            }
            CodexAction::AnswerQuestion {
                request_id,
                answers,
            } => {
                connector.answer_question(&request_id, answers).await?;
            }
            CodexAction::RequestPermissionsResponse {
                request_id,
                permissions,
                scope,
            } => {
                connector
                    .respond_to_permission_request(&request_id, permissions, scope)
                    .await?;
            }
            CodexAction::UpdateConfig {
                approval_policy,
                sandbox_mode,
                permission_mode,
                collaboration_mode,
                multi_agent,
                personality,
                service_tier,
                developer_instructions,
                model,
                effort,
            } => {
                connector
                    .update_config(UpdateConfigOptions {
                        approval_policy: approval_policy.as_deref(),
                        sandbox_mode: sandbox_mode.as_deref(),
                        permission_mode: permission_mode.as_deref(),
                        collaboration_mode: collaboration_mode.as_deref(),
                        multi_agent,
                        personality: personality.as_deref(),
                        service_tier: service_tier.as_deref(),
                        developer_instructions: developer_instructions.as_deref(),
                        model: model.as_deref(),
                        effort: effort.as_deref(),
                    })
                    .await?;
            }
            CodexAction::SetThreadName { name } => {
                connector.set_thread_name(&name).await?;
            }
            CodexAction::ListMcpTools => {
                connector.list_mcp_tools().await?;
            }
            CodexAction::RefreshMcpServers => {
                connector.refresh_mcp_servers().await?;
            }
            CodexAction::Compact => {
                connector.compact().await?;
            }
            CodexAction::Undo => {
                connector.undo().await?;
            }
            CodexAction::ThreadRollback { num_turns } => {
                connector.thread_rollback(num_turns).await?;
            }
            CodexAction::EndSession => {
                connector.shutdown().await?;
            }
            CodexAction::ForkSession {
                nth_user_message,
                model,
                approval_policy,
                sandbox_mode,
                cwd,
                reply_tx,
                ..
            } => {
                let result = connector
                    .fork_thread(
                        nth_user_message,
                        model.as_deref(),
                        approval_policy.as_deref(),
                        sandbox_mode.as_deref(),
                        cwd.as_deref(),
                    )
                    .await;
                let _ = reply_tx.send(result);
            }
        }
        Ok(())
    }
}
