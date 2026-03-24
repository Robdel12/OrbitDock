//! Session runtime utility functions.
//!
//! Shared helpers for runtime-side state transitions and transcript
//! synchronization. Pure time/path helpers live in `support/`.

use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::UNIX_EPOCH;

use tokio::sync::mpsc;

use orbitdock_protocol::conversation_contracts::ConversationRowEntry;
use orbitdock_protocol::{
    ClaudeIntegrationMode, CodexIntegrationMode, Provider, ServerMessage, SessionStatus,
    StateChanges, TokenUsage, WorkStatus,
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct TranscriptSyncUsageSignature {
    input_tokens: u64,
    output_tokens: u64,
    cached_tokens: u64,
    context_window: u64,
}

impl From<&TokenUsage> for TranscriptSyncUsageSignature {
    fn from(value: &TokenUsage) -> Self {
        Self {
            input_tokens: value.input_tokens,
            output_tokens: value.output_tokens,
            cached_tokens: value.cached_tokens,
            context_window: value.context_window,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct TranscriptSyncGuardState {
    transcript_path: String,
    newest_known_id: Option<String>,
    usage: TranscriptSyncUsageSignature,
    file_size: u64,
    modified_at_nanos: Option<u128>,
}

static TRANSCRIPT_SYNC_GUARD_CACHE: OnceLock<Mutex<HashMap<String, TranscriptSyncGuardState>>> =
    OnceLock::new();

fn transcript_sync_guard_cache() -> &'static Mutex<HashMap<String, TranscriptSyncGuardState>> {
    TRANSCRIPT_SYNC_GUARD_CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

async fn build_transcript_sync_guard_state(
    transcript_path: &str,
    newest_known_id: Option<String>,
    usage: &TokenUsage,
) -> Option<TranscriptSyncGuardState> {
    let metadata = tokio::fs::metadata(transcript_path).await.ok()?;
    let modified_at_nanos = metadata
        .modified()
        .ok()
        .and_then(|value| value.duration_since(UNIX_EPOCH).ok())
        .map(|value| value.as_nanos());

    Some(TranscriptSyncGuardState {
        transcript_path: transcript_path.to_string(),
        newest_known_id,
        usage: usage.into(),
        file_size: metadata.len(),
        modified_at_nanos,
    })
}

fn cached_transcript_sync_matches(session_id: &str, candidate: &TranscriptSyncGuardState) -> bool {
    transcript_sync_guard_cache()
        .lock()
        .ok()
        .and_then(|cache| cache.get(session_id).cloned())
        .is_some_and(|previous| previous == *candidate)
}

fn remember_transcript_sync_guard(session_id: &str, state: TranscriptSyncGuardState) {
    if let Ok(mut cache) = transcript_sync_guard_cache().lock() {
        cache.insert(session_id.to_string(), state);
    }
}

fn next_transcript_sync_guard_state(
    candidate: &TranscriptSyncGuardState,
    current_usage: &TokenUsage,
    plan: &crate::runtime::transcript_sync_policy::TranscriptSyncPlan,
    transcript_rows: &[ConversationRowEntry],
) -> TranscriptSyncGuardState {
    let newest_known_id = match plan.message_sync_decision {
        TranscriptMessageSyncDecision::AppendNewMessages
        | TranscriptMessageSyncDecision::ForceResync => {
            transcript_rows.last().map(|row| row.id().to_string())
        }
        TranscriptMessageSyncDecision::SkipNoNewMessages => candidate.newest_known_id.clone(),
    };
    let usage = plan
        .usage_update
        .as_ref()
        .map(|update| TranscriptSyncUsageSignature::from(&update.usage))
        .unwrap_or_else(|| current_usage.into());

    TranscriptSyncGuardState {
        transcript_path: candidate.transcript_path.clone(),
        newest_known_id,
        usage,
        file_size: candidate.file_size,
        modified_at_nanos: candidate.modified_at_nanos,
    }
}

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
            changes: Box::new(StateChanges {
                work_status: Some(WorkStatus::Working),
                last_activity_at: Some(now.clone()),
                ..Default::default()
            }),
            persist_op: Some(PersistOp::SessionUpdate {
                id: session_id.to_string(),
                status: None,
                work_status: Some(WorkStatus::Working),
                last_activity_at: Some(now),
                last_progress_at: None,
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
    let guard_candidate = build_transcript_sync_guard_state(
        &transcript_path,
        newest_known_id.clone(),
        &snap.token_usage,
    )
    .await;

    if let Some(candidate) = guard_candidate.as_ref() {
        if cached_transcript_sync_matches(&session_id, candidate) {
            tracing::info!(
                component = "transcript_sync",
                event = "transcript_sync.skipped_cached",
                session_id = %session_id,
                newest_known_id = ?newest_known_id,
                "Skipping transcript sync because the transcript inputs are unchanged"
            );
            return;
        }
    }

    let all_rows = match load_messages_from_transcript_path(&transcript_path, &session_id).await {
        Ok(rows) => rows,
        Err(_) => return,
    };

    let transcript_row_count = all_rows.len();
    let transcript_rows_for_guard = guard_candidate.as_ref().map(|_| all_rows.clone());
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
    let next_guard_state = match (guard_candidate.as_ref(), transcript_rows_for_guard.as_ref()) {
        (Some(candidate), Some(transcript_rows)) => Some(next_transcript_sync_guard_state(
            candidate,
            &snap.token_usage,
            &plan,
            transcript_rows,
        )),
        _ => None,
    };

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
                actor
                    .send(SessionCommand::ProcessEvent {
                        event: crate::domain::sessions::transition::Input::RowUpdated {
                            row_id: entry.id().to_string(),
                            entry,
                        },
                    })
                    .await;
            }

            for entry in plan.new_rows {
                actor
                    .send(SessionCommand::ProcessEvent {
                        event: crate::domain::sessions::transition::Input::RowCreated(entry),
                    })
                    .await;
            }
        }
        TranscriptMessageSyncDecision::ForceResync => {
            // Full resync — normalize sequences before persisting (matching
            // what replace_rows() does internally), then replace in-memory.
            let mut rows = plan.new_rows;
            for (i, entry) in rows.iter_mut().enumerate() {
                entry.sequence = i as u64;
            }
            for entry in &rows {
                let _ = persist_tx
                    .send(
                        crate::infrastructure::persistence::PersistCommand::RowUpsert {
                            session_id: session_id.clone(),
                            entry: entry.clone(),
                            viewer_present: false,
                            assigned_sequence: Some(entry.sequence),
                            sequence_tx: None,
                        },
                    )
                    .await;
            }
            actor.send(SessionCommand::ReplaceRows { rows }).await;
        }
        TranscriptMessageSyncDecision::SkipNoNewMessages => {}
    }

    if let Some(state) = next_guard_state {
        remember_transcript_sync_guard(&session_id, state);
    }
}

#[cfg(test)]
mod tests {
    use orbitdock_protocol::conversation_contracts::{ConversationRow, MessageRowContent};
    use orbitdock_protocol::TokenUsageSnapshotKind;

    use super::*;

    fn user_row(id: &str, sequence: u64) -> ConversationRowEntry {
        ConversationRowEntry {
            session_id: "session-1".to_string(),
            sequence,
            turn_id: None,
            row: ConversationRow::User(MessageRowContent {
                id: id.to_string(),
                content: format!("row-{sequence}"),
                turn_id: None,
                timestamp: None,
                is_streaming: false,
                images: vec![],
                memory_citation: None,
                delivery_status: None,
            }),
        }
    }

    fn clear_guard_cache() {
        if let Ok(mut cache) = transcript_sync_guard_cache().lock() {
            cache.clear();
        }
    }

    #[test]
    fn cached_transcript_sync_only_skips_identical_inputs() {
        clear_guard_cache();
        let session_id = "session-cache-test";
        let candidate = TranscriptSyncGuardState {
            transcript_path: "/tmp/transcript.jsonl".to_string(),
            newest_known_id: Some("row-2".to_string()),
            usage: TranscriptSyncUsageSignature {
                input_tokens: 1,
                output_tokens: 2,
                cached_tokens: 3,
                context_window: 4,
            },
            file_size: 128,
            modified_at_nanos: Some(42),
        };

        remember_transcript_sync_guard(session_id, candidate.clone());
        assert!(cached_transcript_sync_matches(session_id, &candidate));
        assert!(!cached_transcript_sync_matches(
            session_id,
            &TranscriptSyncGuardState {
                file_size: 129,
                ..candidate
            }
        ));
        clear_guard_cache();
    }

    #[test]
    fn next_guard_state_advances_newest_row_and_usage_after_append() {
        let current_usage = TokenUsage {
            input_tokens: 10,
            output_tokens: 20,
            cached_tokens: 30,
            context_window: 40,
        };
        let next_usage = TokenUsage {
            input_tokens: 11,
            output_tokens: 22,
            cached_tokens: 33,
            context_window: 44,
        };
        let candidate = TranscriptSyncGuardState {
            transcript_path: "/tmp/transcript.jsonl".to_string(),
            newest_known_id: Some("row-1".to_string()),
            usage: TranscriptSyncUsageSignature::from(&current_usage),
            file_size: 128,
            modified_at_nanos: Some(42),
        };
        let transcript_rows = vec![user_row("row-1", 0), user_row("row-2", 1)];
        let plan = crate::runtime::transcript_sync_policy::TranscriptSyncPlan {
            usage_update: Some(
                crate::runtime::transcript_sync_policy::TranscriptUsageUpdate {
                    usage: next_usage.clone(),
                    snapshot_kind: TokenUsageSnapshotKind::MixedLegacy,
                },
            ),
            message_sync_decision: TranscriptMessageSyncDecision::AppendNewMessages,
            new_rows: vec![transcript_rows[1].clone()],
            updated_rows: vec![],
        };

        let next =
            next_transcript_sync_guard_state(&candidate, &current_usage, &plan, &transcript_rows);

        assert_eq!(next.newest_known_id.as_deref(), Some("row-2"));
        assert_eq!(next.usage, TranscriptSyncUsageSignature::from(&next_usage));
        assert_eq!(next.file_size, candidate.file_size);
        assert_eq!(next.modified_at_nanos, candidate.modified_at_nanos);
    }
}
