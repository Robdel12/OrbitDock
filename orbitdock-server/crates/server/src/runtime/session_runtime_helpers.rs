//! Session runtime utility functions.
//!
//! Shared helpers for runtime-side state transitions and transcript
//! synchronization. Pure time/path helpers live in `support/`.

use std::collections::BTreeMap;
use std::sync::Arc;

use tokio::sync::mpsc;

use orbitdock_protocol::conversation_contracts::ConversationRowEntry;
use orbitdock_protocol::{
    ClaudeIntegrationMode, CodexIntegrationMode, Provider, ServerMessage, SessionStatus,
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

fn normalize_row_sequences(rows: &mut [ConversationRowEntry]) {
    let mut next_sequence = 0_u64;
    for entry in rows {
        if entry.sequence == 0 && next_sequence > 0 {
            entry.sequence = next_sequence;
        }
        next_sequence = entry.sequence + 1;
    }
}

pub(crate) fn merge_rows_by_sequence(
    mut base: Vec<ConversationRowEntry>,
    mut overlay: Vec<ConversationRowEntry>,
) -> Vec<ConversationRowEntry> {
    normalize_row_sequences(&mut base);
    normalize_row_sequences(&mut overlay);

    let mut merged = BTreeMap::<u64, ConversationRowEntry>::new();
    for entry in base {
        merged.insert(entry.sequence, entry);
    }
    for entry in overlay {
        merged.insert(entry.sequence, entry);
    }
    merged.into_values().collect()
}

pub(crate) async fn hydrate_full_row_history(
    session_id: &str,
    retained_rows: Vec<ConversationRowEntry>,
    total_row_count: Option<u64>,
) -> Vec<ConversationRowEntry> {
    let expected_count = total_row_count.unwrap_or(retained_rows.len() as u64);
    if retained_rows.len() as u64 >= expected_count {
        return retained_rows;
    }

    match load_messages_for_session(session_id).await {
        Ok(db_rows) if !db_rows.is_empty() => merge_rows_by_sequence(db_rows, retained_rows),
        _ => retained_rows,
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
        state.broadcast_to_list(ServerMessage::SessionListItemRemoved {
            session_id: thread_id.to_string(),
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

/// Re-read a session's transcript and broadcast any new rows to subscribers.
/// Works for any hook-triggered session (Claude CLI, future Codex CLI hooks).
///
/// Uses ID-based comparison: tracks the newest row ID we've synced rather than
/// a count. This is immune to `total_row_count` inflation from upserts.
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
    let newest_known_id = snap.newest_synced_row_id.clone();

    let all_rows = match load_messages_from_transcript_path(&transcript_path, &session_id).await {
        Ok(rows) => rows,
        Err(_) => return,
    };

    let transcript_row_count = all_rows.len();
    let plan = plan_transcript_sync(TranscriptSyncInputs {
        provider: snap.provider,
        current_usage: snap.token_usage.clone(),
        transcript_usage: load_token_usage_from_transcript_path(&transcript_path)
            .await
            .ok()
            .flatten(),
        transcript_rows: all_rows,
        newest_known_id: newest_known_id.clone(),
    });

    tracing::info!(
        component = "transcript_sync",
        event = "transcript_sync.planned",
        session_id = %session_id,
        transcript_rows = transcript_row_count,
        newest_known_id = ?newest_known_id,
        decision = ?plan.message_sync_decision,
        new_rows = plan.new_rows.len(),
        updated_rows = plan.updated_rows.len(),
        "Transcript sync planned"
    );

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

    match plan.message_sync_decision {
        TranscriptMessageSyncDecision::AppendNewMessages => {
            // Upsert existing rows that got results attached by the transcript parser.
            for entry in plan.updated_rows {
                let _ = persist_tx
                    .send(
                        crate::infrastructure::persistence::PersistCommand::RowUpsert {
                            session_id: session_id.clone(),
                            entry: entry.clone(),
                        },
                    )
                    .await;
                actor
                    .send(SessionCommand::UpsertRowAndBroadcast { entry })
                    .await;
            }

            for entry in plan.new_rows {
                let _ = persist_tx
                    .send(
                        crate::infrastructure::persistence::PersistCommand::RowAppend {
                            session_id: session_id.clone(),
                            entry: entry.clone(),
                        },
                    )
                    .await;
                actor
                    .send(SessionCommand::AddRowAndBroadcast { entry })
                    .await;
            }
        }
        TranscriptMessageSyncDecision::ForceResync => {
            // Full resync — replace all rows in-memory and broadcast
            for entry in &plan.new_rows {
                let _ = persist_tx
                    .send(
                        crate::infrastructure::persistence::PersistCommand::RowUpsert {
                            session_id: session_id.clone(),
                            entry: entry.clone(),
                        },
                    )
                    .await;
            }
            actor
                .send(SessionCommand::ReplaceRows {
                    rows: plan.new_rows,
                })
                .await;
        }
        TranscriptMessageSyncDecision::SkipNoNewMessages => {}
    }
}
