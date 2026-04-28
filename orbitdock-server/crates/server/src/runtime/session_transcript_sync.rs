use tokio::sync::mpsc;

use crate::infrastructure::persistence::{
  load_messages_from_transcript_path, load_token_usage_from_transcript_path, PersistCommand,
};
use crate::runtime::session_actor::SessionActorHandle;
use crate::runtime::session_commands::SessionCommand;
use crate::runtime::transcript_sync_guard::{
  build_transcript_sync_guard_state, cached_transcript_sync_matches,
  next_transcript_sync_guard_state, remember_transcript_sync_guard,
};
use crate::runtime::transcript_sync_policy::{
  plan_transcript_sync, TranscriptMessageSyncDecision, TranscriptSyncInputs,
};

/// Re-read a session's transcript and broadcast any new rows to subscribers.
/// Works for any hook-triggered session (Claude CLI, future Codex CLI hooks).
///
/// Uses ID-based comparison: tracks the newest row ID we've synced rather than
/// a count. This is immune to `total_row_count` inflation from upserts.
pub(crate) async fn sync_transcript_messages(
  actor: &SessionActorHandle,
  persist_tx: &mpsc::Sender<PersistCommand>,
) {
  let snap = actor.snapshot();
  let transcript_path = match snap.transcript_path.as_deref() {
    Some(p) => p.to_string(),
    None => return,
  };
  let session_id = snap.id.clone();
  let newest_known_id = snap.newest_synced_row_id.clone();
  let guard_candidate =
    build_transcript_sync_guard_state(&transcript_path, newest_known_id.clone(), &snap.token_usage)
      .await;

  if let Some(candidate) = guard_candidate.as_ref() {
    if cached_transcript_sync_matches(&session_id, candidate) {
      tracing::debug!(
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
      let mut rows = plan.new_rows;
      for (i, entry) in rows.iter_mut().enumerate() {
        entry.sequence = i as u64;
      }
      for entry in &rows {
        let _ = persist_tx
          .send(PersistCommand::RowUpsert {
            session_id: session_id.clone(),
            entry: entry.clone(),
            viewer_present: false,
            assigned_sequence: Some(entry.sequence),
            sequence_tx: None,
          })
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
