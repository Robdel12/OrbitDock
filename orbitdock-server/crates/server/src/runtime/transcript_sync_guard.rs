use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use std::time::UNIX_EPOCH;

use orbitdock_protocol::conversation_contracts::ConversationRowEntry;
use orbitdock_protocol::TokenUsage;

use crate::runtime::transcript_sync_policy::{TranscriptMessageSyncDecision, TranscriptSyncPlan};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct TranscriptSyncUsageSignature {
  pub(crate) input_tokens: u64,
  pub(crate) output_tokens: u64,
  pub(crate) cached_tokens: u64,
  pub(crate) context_window: u64,
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
pub(crate) struct TranscriptSyncGuardState {
  pub(crate) transcript_path: String,
  pub(crate) newest_known_id: Option<String>,
  pub(crate) usage: TranscriptSyncUsageSignature,
  pub(crate) file_size: u64,
  pub(crate) modified_at_nanos: Option<u128>,
}

static TRANSCRIPT_SYNC_GUARD_CACHE: OnceLock<Mutex<HashMap<String, TranscriptSyncGuardState>>> =
  OnceLock::new();

pub(crate) fn transcript_sync_guard_cache(
) -> &'static Mutex<HashMap<String, TranscriptSyncGuardState>> {
  TRANSCRIPT_SYNC_GUARD_CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

pub(crate) async fn build_transcript_sync_guard_state(
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

pub(crate) fn cached_transcript_sync_matches(
  session_id: &str,
  candidate: &TranscriptSyncGuardState,
) -> bool {
  transcript_sync_guard_cache()
    .lock()
    .ok()
    .and_then(|cache| cache.get(session_id).cloned())
    .is_some_and(|previous| previous == *candidate)
}

pub(crate) fn remember_transcript_sync_guard(session_id: &str, state: TranscriptSyncGuardState) {
  if let Ok(mut cache) = transcript_sync_guard_cache().lock() {
    cache.insert(session_id.to_string(), state);
  }
}

pub(crate) fn next_transcript_sync_guard_state(
  candidate: &TranscriptSyncGuardState,
  current_usage: &TokenUsage,
  plan: &TranscriptSyncPlan,
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
