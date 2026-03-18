use std::sync::Arc;

use orbitdock_protocol::{ServerMessage, SessionListItem};

use crate::connectors::claude_session::ClaudeAction;
use crate::connectors::codex_session::CodexAction;
use crate::infrastructure::persistence::PersistCommand;
use crate::runtime::session_commands::{PersistOp, SessionCommand};
use crate::runtime::session_registry::SessionRegistry;
use crate::support::session_modes::is_passive_rollout_session;

pub(crate) enum SessionMutationError {
    NotFound(String),
}

#[derive(Debug, Clone, Default)]
pub(crate) struct SessionConfigUpdate {
    pub approval_policy: Option<String>,
    pub sandbox_mode: Option<String>,
    pub permission_mode: Option<String>,
    pub collaboration_mode: Option<String>,
    pub multi_agent: Option<bool>,
    pub personality: Option<String>,
    pub service_tier: Option<String>,
    pub developer_instructions: Option<String>,
    pub model: Option<String>,
    pub effort: Option<String>,
}

impl SessionMutationError {
    pub(crate) fn code(&self) -> &'static str {
        match self {
            Self::NotFound(_) => "not_found",
        }
    }

    pub(crate) fn message(&self) -> String {
        match self {
            Self::NotFound(session_id) => format!("Session {session_id} not found"),
        }
    }
}

pub(crate) async fn rename_session(
    state: &Arc<SessionRegistry>,
    session_id: &str,
    name: Option<String>,
) -> Result<(), SessionMutationError> {
    let actor = state
        .get_session(session_id)
        .ok_or_else(|| SessionMutationError::NotFound(session_id.to_string()))?;

    let (reply_tx, reply_rx) = tokio::sync::oneshot::channel();
    actor
        .send(SessionCommand::SetCustomNameAndNotify {
            name: name.clone(),
            persist_op: Some(PersistOp::SetCustomName {
                session_id: session_id.to_string(),
                name: name.clone(),
            }),
            reply: reply_tx,
        })
        .await;

    if let Ok(summary) = reply_rx.await {
        state.broadcast_to_list(ServerMessage::SessionListItemUpdated {
            session: SessionListItem::from_summary(&summary),
        });
    }

    if let Some(ref name) = name {
        if let Some(tx) = state.get_codex_action_tx(session_id) {
            let _ = tx
                .send(CodexAction::SetThreadName { name: name.clone() })
                .await;
        }
    }

    Ok(())
}

pub(crate) async fn update_session_config(
    state: &Arc<SessionRegistry>,
    session_id: &str,
    update: SessionConfigUpdate,
) -> Result<(), SessionMutationError> {
    let SessionConfigUpdate {
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
    } = update;
    let actor = state
        .get_session(session_id)
        .ok_or_else(|| SessionMutationError::NotFound(session_id.to_string()))?;

    actor
        .send(SessionCommand::ApplyDelta {
            changes: orbitdock_protocol::StateChanges {
                approval_policy: Some(approval_policy.clone()),
                sandbox_mode: Some(sandbox_mode.clone()),
                permission_mode: Some(permission_mode.clone()),
                collaboration_mode: Some(collaboration_mode.clone()),
                multi_agent: Some(multi_agent),
                personality: Some(personality.clone()),
                service_tier: Some(service_tier.clone()),
                developer_instructions: Some(developer_instructions.clone()),
                model: Some(model.clone()),
                effort: Some(effort.clone()),
                ..Default::default()
            },
            persist_op: Some(PersistOp::SetSessionConfig {
                session_id: session_id.to_string(),
                approval_policy: approval_policy.clone(),
                sandbox_mode: sandbox_mode.clone(),
                permission_mode: permission_mode.clone(),
                collaboration_mode: collaboration_mode.clone(),
                multi_agent,
                personality: personality.clone(),
                service_tier: service_tier.clone(),
                developer_instructions: developer_instructions.clone(),
                model: model.clone(),
                effort: effort.clone(),
            }),
        })
        .await;

    if let Ok(summary) = actor.summary().await {
        state.broadcast_to_list(ServerMessage::SessionListItemUpdated {
            session: SessionListItem::from_summary(&summary),
        });
    }

    if let Some(ref mode) = permission_mode {
        if let Some(tx) = state.get_claude_action_tx(session_id) {
            let _ = tx
                .send(ClaudeAction::SetPermissionMode { mode: mode.clone() })
                .await;
        }
    }

    if let Some(tx) = state.get_codex_action_tx(session_id) {
        let _ = tx
            .send(CodexAction::UpdateConfig {
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
            })
            .await;
    }

    Ok(())
}

pub(crate) async fn end_session(state: &Arc<SessionRegistry>, session_id: &str) -> usize {
    let actor = state.get_session(session_id);
    let is_passive_rollout = actor.as_ref().is_some_and(|actor| {
        let snap = actor.snapshot();
        is_passive_rollout_session(
            snap.provider,
            snap.codex_integration_mode,
            snap.transcript_path.is_some(),
        )
    });

    let canceled_shells = state.shell_service().cancel_session(session_id);

    if !is_passive_rollout {
        if let Some(tx) = state.get_codex_action_tx(session_id) {
            let _ = tx.send(CodexAction::EndSession).await;
        } else if let Some(tx) = state.get_claude_action_tx(session_id) {
            let _ = tx.send(ClaudeAction::EndSession).await;
        }
    }

    let _ = state
        .persist()
        .send(PersistCommand::SessionEnd {
            id: session_id.to_string(),
            reason: "user_requested".to_string(),
        })
        .await;

    if is_passive_rollout {
        if let Some(actor) = actor {
            actor.send(SessionCommand::EndLocally).await;
        }
        state.broadcast_to_list(ServerMessage::SessionEnded {
            session_id: session_id.to_string(),
            reason: "user_requested".to_string(),
        });
    } else if state.remove_session(session_id).is_some() {
        state.broadcast_to_list(ServerMessage::SessionEnded {
            session_id: session_id.to_string(),
            reason: "user_requested".to_string(),
        });
    }

    canceled_shells
}

pub(crate) async fn send_continuation_message(
    state: &Arc<SessionRegistry>,
    session_id: &str,
    content: &str,
) -> bool {
    if let Some(tx) = state.get_claude_action_tx(session_id) {
        tx.send(ClaudeAction::SendMessage {
            content: content.to_string(),
            model: None,
            effort: None,
            images: vec![],
        })
        .await
        .is_ok()
    } else {
        false
    }
}

pub(crate) async fn end_failed_direct_session(state: &Arc<SessionRegistry>, session_id: &str) {
    let _ = state
        .persist()
        .send(PersistCommand::SessionEnd {
            id: session_id.to_string(),
            reason: "connector_failed".to_string(),
        })
        .await;
    state.broadcast_to_list(ServerMessage::SessionEnded {
        session_id: session_id.to_string(),
        reason: "connector_failed".into(),
    });
}
