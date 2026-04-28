use crate::runtime::session_transcript_sync::sync_transcript_messages;

use super::routing::ClaudeHookHandlingOptions;

pub(crate) async fn maybe_sync_transcript_messages(
  actor: &crate::runtime::session_actor::SessionActorHandle,
  persist_tx: &tokio::sync::mpsc::Sender<crate::infrastructure::persistence::PersistCommand>,
  options: &ClaudeHookHandlingOptions,
) {
  let session_id = actor.snapshot().id.clone();
  if !options.should_sync_transcript(&session_id).await {
    return;
  }

  sync_transcript_messages(actor, persist_tx).await;
}
