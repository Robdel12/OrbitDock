//! Session lifecycle utility functions.
//!
//! Shared helpers for timestamps, session state transitions, transcript
//! syncing, and path resolution. Used by WebSocket handlers, hook
//! handlers, and session management code.

use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use tokio::sync::{mpsc, oneshot};

use orbitdock_protocol::{
    ClaudeIntegrationMode, CodexIntegrationMode, Provider, ServerMessage, SessionStatus,
    StateChanges, TokenUsageSnapshotKind, WorkStatus,
};

use crate::persistence::{
    load_messages_from_transcript_path, load_token_usage_from_transcript_path, PersistCommand,
};
use crate::session_actor::SessionActorHandle;
use crate::session_command::{PersistOp, SessionCommand};
use crate::state::SessionRegistry;

pub(crate) const CLAUDE_EMPTY_SHELL_TTL_SECS: u64 = 5 * 60;

pub(crate) fn chrono_now() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    format!("{}Z", secs)
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

pub(crate) fn parse_unix_z(value: Option<&str>) -> Option<u64> {
    let raw = value?;
    let stripped = raw.strip_suffix('Z').unwrap_or(raw);
    stripped.parse::<u64>().ok()
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

pub(crate) fn project_name_from_cwd(cwd: &str) -> Option<String> {
    std::path::Path::new(cwd)
        .file_name()
        .and_then(|s| s.to_str())
        .map(|s| s.to_string())
}

pub(crate) fn claude_transcript_path_from_cwd(cwd: &str, session_id: &str) -> Option<String> {
    let home = std::env::var("HOME").ok()?;
    let trimmed = cwd.trim_start_matches('/');
    if trimmed.is_empty() {
        return None;
    }
    let dir = format!("-{}", trimmed.replace('/', "-"));
    Some(format!(
        "{}/.claude/projects/{}/{}.jsonl",
        home, dir, session_id
    ))
}

/// Re-read a session's transcript and broadcast any new messages to subscribers.
/// Works for any hook-triggered session (Claude CLI, future Codex CLI hooks).
pub(crate) async fn sync_transcript_messages(
    actor: &SessionActorHandle,
    persist_tx: &tokio::sync::mpsc::Sender<crate::persistence::PersistCommand>,
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

    if let Ok(Some(usage)) = load_token_usage_from_transcript_path(&transcript_path).await {
        let current_usage = &snap.token_usage;
        if usage.input_tokens != current_usage.input_tokens
            || usage.output_tokens != current_usage.output_tokens
            || usage.cached_tokens != current_usage.cached_tokens
            || usage.context_window != current_usage.context_window
        {
            actor
                .send(SessionCommand::ProcessEvent {
                    event: crate::transition::Input::TokensUpdated {
                        usage,
                        snapshot_kind: match snap.provider {
                            Provider::Codex => TokenUsageSnapshotKind::ContextTurn,
                            Provider::Claude => TokenUsageSnapshotKind::MixedLegacy,
                        },
                    },
                })
                .await;
        }
    }

    if all_messages.len() <= existing_count {
        return;
    }

    let new_messages = all_messages[existing_count..].to_vec();

    // Double-check count hasn't changed while we were reading
    let (count_tx, count_rx) = oneshot::channel();
    actor
        .send(SessionCommand::GetMessageCount { reply: count_tx })
        .await;
    if let Ok(current_count) = count_rx.await {
        if current_count != existing_count {
            return;
        }
    }

    for msg in new_messages {
        let _ = persist_tx
            .send(crate::persistence::PersistCommand::MessageAppend {
                session_id: session_id.clone(),
                message: msg.clone(),
            })
            .await;
        actor
            .send(SessionCommand::AddMessageAndBroadcast { message: msg })
            .await;
    }
}

/// Format millis-since-epoch as ISO 8601 timestamp
pub(crate) fn iso_timestamp(millis: u128) -> String {
    let total_secs = millis / 1000;
    let secs = total_secs % 60;
    let total_mins = total_secs / 60;
    let mins = total_mins % 60;
    let total_hours = total_mins / 60;
    let hours = total_hours % 24;
    let days_since_epoch = total_hours / 24;

    // Simplified date calc (good enough for timestamps)
    let mut y = 1970i64;
    let mut remaining_days = days_since_epoch as i64;
    loop {
        let days_in_year = if (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 {
            366
        } else {
            365
        };
        if remaining_days < days_in_year {
            break;
        }
        remaining_days -= days_in_year;
        y += 1;
    }
    let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
    let month_days = [
        31,
        if leap { 29 } else { 28 },
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31,
    ];
    let mut m = 0usize;
    for &md in &month_days {
        if remaining_days < md {
            break;
        }
        remaining_days -= md;
        m += 1;
    }
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        y,
        m + 1,
        remaining_days + 1,
        hours,
        mins,
        secs
    )
}

/// Resolve the correct cwd for `claude --resume` by matching the transcript
/// path's project hash against the session's project_path (and its parents).
///
/// Claude stores transcripts at `~/.claude/projects/<hash>/<session>.jsonl`
/// where `<hash>` encodes the cwd with `/` and `.` replaced by `-`.
/// The DB's `project_path` may be a subdirectory, so we walk up until
/// we find a path whose hash matches the transcript's project directory.
pub(crate) fn resolve_claude_resume_cwd(project_path: &str, transcript_path: &str) -> String {
    let expected_hash = std::path::Path::new(transcript_path)
        .parent()
        .and_then(|p| p.file_name())
        .and_then(|n| n.to_str());

    let Some(expected) = expected_hash else {
        return project_path.to_string();
    };

    let mut candidate = std::path::PathBuf::from(project_path);
    for _ in 0..5 {
        let hash = candidate.to_string_lossy().replace(['/', '.'], "-");
        if hash == expected {
            return candidate.to_string_lossy().to_string();
        }
        if !candidate.pop() {
            break;
        }
    }

    // Fallback: use project_path as-is
    project_path.to_string()
}
