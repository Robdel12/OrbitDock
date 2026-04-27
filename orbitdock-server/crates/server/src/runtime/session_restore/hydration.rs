use crate::infrastructure::persistence::{load_messages_from_transcript_path, RestoredSession};

pub(crate) async fn hydrate_restored_rows_if_missing(
  restored: &mut RestoredSession,
  session_id: &str,
) {
  if !restored.rows.is_empty() {
    return;
  }

  if let Some(transcript_path) = restored.transcript_path.as_ref() {
    if let Ok(rows) = load_messages_from_transcript_path(transcript_path, session_id).await {
      if !rows.is_empty() {
        restored.rows = rows;
      }
    }
  }
}
