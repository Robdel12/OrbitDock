use std::time::{Duration, Instant};

use super::{RowEntrySummary, SessionHandle};
use crate::domain::sessions::conversation_state::{
  is_actively_streaming_message_row_summary, is_message_row_summary,
  streaming_message_row_summary_content_len,
};

const STREAMING_ROW_BROADCAST_THROTTLE: Duration = Duration::from_millis(250);
const STREAMING_ROW_FORCE_EMIT_CONTENT_STEP: usize = 24;
const STREAMING_ROW_MIN_INITIAL_EMIT_CHARS: usize = 8;

#[derive(Debug, Clone)]
pub(super) struct StreamingRowEmitState {
  last_emit_at: Instant,
  last_emitted_content_len: usize,
}

impl SessionHandle {
  pub fn should_emit_streaming_row_update(&mut self, upserted: &[RowEntrySummary]) -> bool {
    if upserted.len() != 1 {
      for entry in upserted {
        if !is_actively_streaming_message_row_summary(entry) {
          self.streaming_row_emit_at.remove(entry.id());
        }
      }
      return true;
    }

    let entry = &upserted[0];
    if !is_message_row_summary(entry) {
      self.streaming_row_emit_at.remove(entry.id());
      return true;
    }
    if !is_actively_streaming_message_row_summary(entry) {
      self.streaming_row_emit_at.remove(entry.id());
      return true;
    }

    let content_len = streaming_message_row_summary_content_len(entry).unwrap_or(0);
    let now = Instant::now();
    match self.streaming_row_emit_at.get_mut(entry.id()) {
      Some(state) => {
        let force_emit_for_growth =
          content_len >= state.last_emitted_content_len + STREAMING_ROW_FORCE_EMIT_CONTENT_STEP;
        if !force_emit_for_growth
          && now.duration_since(state.last_emit_at) < STREAMING_ROW_BROADCAST_THROTTLE
        {
          false
        } else {
          state.last_emit_at = now;
          state.last_emitted_content_len = content_len;
          true
        }
      }
      None => {
        self.streaming_row_emit_at.insert(
          entry.id().to_string(),
          StreamingRowEmitState {
            last_emit_at: now,
            last_emitted_content_len: 0,
          },
        );
        content_len >= STREAMING_ROW_MIN_INITIAL_EMIT_CHARS
      }
    }
  }
}
