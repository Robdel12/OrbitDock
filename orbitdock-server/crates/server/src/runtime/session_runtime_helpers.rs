//! Session runtime utility functions.
//!
//! Shared helpers for runtime-side state transitions and transcript
//! synchronization. Pure time/path helpers live in `support/`.

use std::collections::BTreeMap;
use std::sync::Arc;

use tokio::sync::{mpsc, oneshot};

use orbitdock_protocol::{
    ClaudeIntegrationMode, CodexIntegrationMode, Message, Provider, ServerMessage, SessionStatus,
    StateChanges, WorkStatus,
};

use crate::infrastructure::persistence::{
    load_messages_for_session, load_messages_from_transcript_path,
    load_token_usage_from_transcript_path, PersistCommand,
};
use crate::runtime::session_actor::SessionActorHandle;
use crate::runtime::session_commands::{PersistOp, SessionCommand};
use crate::runtime::session_registry::SessionRegistry;
use crate::runtime::transcript_sync_policy::{
    plan_transcript_sync, TranscriptMessageSyncDecision, TranscriptSyncInputs,
};
use crate::support::session_time::{chrono_now, parse_unix_z};

pub(crate) const CLAUDE_EMPTY_SHELL_TTL_SECS: u64 = 5 * 60;

fn normalize_message_sequences(messages: &mut [Message]) {
    let mut next_sequence = 0_u64;
    for message in messages {
        let sequence = message.sequence.unwrap_or(next_sequence);
        message.sequence = Some(sequence);
        next_sequence = sequence + 1;
    }
}

pub(crate) fn merge_messages_by_sequence(
    mut base: Vec<Message>,
    mut overlay: Vec<Message>,
) -> Vec<Message> {
    normalize_message_sequences(&mut base);
    normalize_message_sequences(&mut overlay);

    let mut merged = BTreeMap::<u64, Message>::new();
    for message in base {
        if let Some(sequence) = message.sequence {
            merged.insert(sequence, message);
        }
    }
    for message in overlay {
        if let Some(sequence) = message.sequence {
            merged.insert(sequence, message);
        }
    }
    merged.into_values().collect()
}

pub(crate) async fn hydrate_full_message_history(
    session_id: &str,
    retained_messages: Vec<Message>,
    total_message_count: Option<u64>,
) -> Vec<Message> {
    let expected_count = total_message_count.unwrap_or(retained_messages.len() as u64);
    if retained_messages.len() as u64 >= expected_count {
        return retained_messages;
    }

    match load_messages_for_session(session_id).await {
        Ok(db_messages) if !db_messages.is_empty() => {
            merge_messages_by_sequence(db_messages, retained_messages)
        }
        _ => retained_messages,
    }
}

pub(crate) async fn mark_session_working_after_send(
    state: &Arc<SessionRegistry>,
    session_id: &str,
) {
    let Some(actor) = state.get_session(session_id) else {
        return;
    };

    let now = chrono_now();
    actor
        .send(SessionCommand::ApplyDelta {
            changes: StateChanges {
                work_status: Some(WorkStatus::Working),
                last_activity_at: Some(now.clone()),
                ..Default::default()
            },
            persist_op: Some(PersistOp::SessionUpdate {
                id: session_id.to_string(),
                status: None,
                work_status: Some(WorkStatus::Working),
                last_activity_at: Some(now),
            }),
        })
        .await;
}

pub(crate) async fn claim_codex_thread_for_direct_session(
    state: &Arc<SessionRegistry>,
    persist_tx: &mpsc::Sender<PersistCommand>,
    session_id: &str,
    thread_id: &str,
    cleanup_reason: &str,
) {
    let _ = persist_tx
        .send(PersistCommand::SetThreadId {
            session_id: session_id.to_string(),
            thread_id: thread_id.to_string(),
        })
        .await;
    state.register_codex_thread(session_id, thread_id);

    if thread_id != session_id && state.remove_session(thread_id).is_some() {
        state.broadcast_to_list(ServerMessage::SessionEnded {
            session_id: thread_id.to_string(),
            reason: "direct_session_thread_claimed".into(),
        });
    }

    let _ = persist_tx
        .send(PersistCommand::CleanupThreadShadowSession {
            thread_id: thread_id.to_string(),
            reason: cleanup_reason.to_string(),
        })
        .await;
}

pub(crate) fn direct_mode_activation_changes(provider: Provider) -> StateChanges {
    let mut changes = StateChanges {
        status: Some(SessionStatus::Active),
        work_status: Some(WorkStatus::Waiting),
        ..Default::default()
    };

    match provider {
        Provider::Codex => {
            changes.codex_integration_mode = Some(Some(CodexIntegrationMode::Direct));
        }
        Provider::Claude => {
            changes.claude_integration_mode = Some(Some(ClaudeIntegrationMode::Direct));
        }
    }

    changes
}

#[cfg(test)]
mod tests {
    use super::direct_mode_activation_changes;
    use orbitdock_protocol::{
        ClaudeIntegrationMode, CodexIntegrationMode, Provider, SessionStatus, WorkStatus,
    };

    #[test]
    fn direct_mode_activation_changes_sets_active_waiting_for_codex() {
        let changes = direct_mode_activation_changes(Provider::Codex);
        assert_eq!(changes.status, Some(SessionStatus::Active));
        assert_eq!(changes.work_status, Some(WorkStatus::Waiting));
        assert_eq!(
            changes.codex_integration_mode,
            Some(Some(CodexIntegrationMode::Direct))
        );
        assert_eq!(changes.claude_integration_mode, None);
    }

    #[test]
    fn direct_mode_activation_changes_sets_active_waiting_for_claude() {
        let changes = direct_mode_activation_changes(Provider::Claude);
        assert_eq!(changes.status, Some(SessionStatus::Active));
        assert_eq!(changes.work_status, Some(WorkStatus::Waiting));
        assert_eq!(
            changes.claude_integration_mode,
            Some(Some(ClaudeIntegrationMode::Direct))
        );
        assert_eq!(changes.codex_integration_mode, None);
    }
}

pub(crate) fn is_stale_empty_claude_shell(
    summary: &orbitdock_protocol::SessionSummary,
    current_session_id: &str,
    cwd: &str,
    now_secs: u64,
) -> bool {
    if summary.id == current_session_id {
        return false;
    }
    if summary.provider != Provider::Claude {
        return false;
    }
    if summary.project_path != cwd {
        return false;
    }
    if summary.status != orbitdock_protocol::SessionStatus::Active {
        return false;
    }
    if summary.work_status != orbitdock_protocol::WorkStatus::Waiting {
        return false;
    }
    if summary.custom_name.is_some() {
        return false;
    }

    let started_at = parse_unix_z(summary.started_at.as_deref());
    let last_activity_at = parse_unix_z(summary.last_activity_at.as_deref()).or(started_at);
    let Some(last_activity_at) = last_activity_at else {
        return false;
    };

    now_secs.saturating_sub(last_activity_at) >= CLAUDE_EMPTY_SHELL_TTL_SECS
}

/// Re-read a session's transcript and broadcast any new messages to subscribers.
/// Works for any hook-triggered session (Claude CLI, future Codex CLI hooks).
pub(crate) async fn sync_transcript_messages(
    actor: &SessionActorHandle,
    persist_tx: &tokio::sync::mpsc::Sender<crate::infrastructure::persistence::PersistCommand>,
) {
    let snap = actor.snapshot();
    let transcript_path = match snap.transcript_path.as_deref() {
        Some(p) => p.to_string(),
        None => return,
    };
    let session_id = snap.id.clone();
    let existing_count = snap.message_count;

    let all_messages = match load_messages_from_transcript_path(&transcript_path, &session_id).await
    {
        Ok(msgs) => msgs,
        Err(_) => return,
    };

    // Double-check count hasn't changed while we were reading
    let (count_tx, count_rx) = oneshot::channel();
    actor
        .send(SessionCommand::GetMessageCount { reply: count_tx })
        .await;
    let confirmed_count = count_rx.await.ok();

    let plan = plan_transcript_sync(TranscriptSyncInputs {
        provider: snap.provider,
        current_usage: snap.token_usage.clone(),
        transcript_usage: load_token_usage_from_transcript_path(&transcript_path)
            .await
            .ok()
            .flatten(),
        transcript_messages: all_messages,
        existing_count,
        confirmed_count,
    });

    if let Some(usage_update) = plan.usage_update {
        actor
            .send(SessionCommand::ProcessEvent {
                event: crate::domain::sessions::transition::Input::TokensUpdated {
                    usage: usage_update.usage,
                    snapshot_kind: usage_update.snapshot_kind,
                },
            })
            .await;
    }

    if matches!(
        plan.message_sync_decision,
        TranscriptMessageSyncDecision::AppendNewMessages
    ) {
        for msg in plan.new_messages {
            let _ = persist_tx
                .send(
                    crate::infrastructure::persistence::PersistCommand::MessageAppend {
                        session_id: session_id.clone(),
                        message: msg.clone(),
                    },
                )
                .await;
            actor
                .send(SessionCommand::AddMessageAndBroadcast { message: msg })
                .await;
        }
    }
}
