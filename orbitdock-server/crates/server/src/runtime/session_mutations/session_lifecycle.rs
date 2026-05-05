use std::sync::Arc;

use orbitdock_protocol::ServerMessage;

use crate::connectors::claude_session::ClaudeAction;
use crate::connectors::codex_session::CodexAction;
use crate::infrastructure::persistence::PersistCommand;
use crate::runtime::session_registry::SessionRegistry;
use crate::support::session_modes::is_passive_rollout_session;

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

  if let Some(actor) = actor.as_ref() {
    actor
      .send(crate::runtime::session_commands::SessionCommand::EndLocally)
      .await;
  }

  if is_passive_rollout || state.remove_session(session_id).is_some() {
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
      mentions: vec![],
    })
    .await
    .is_ok()
  } else {
    false
  }
}

pub(crate) async fn sync_mission_issue_on_resume(
  state: &Arc<SessionRegistry>,
  session_id: &str,
  mission_id: &str,
) {
  let now = chrono::Utc::now().to_rfc3339();

  let db_path = state.db_path().clone();
  let sid = session_id.to_string();
  let mid = mission_id.to_string();
  let issue_id = tokio::task::spawn_blocking(move || {
    let conn = rusqlite::Connection::open(&db_path).ok()?;
    let mut stmt = conn
      .prepare(
        "SELECT issue_id FROM mission_issues \
                 WHERE mission_id = ?1 AND session_id = ?2 \
                 LIMIT 1",
      )
      .ok()?;
    stmt
      .query_row(rusqlite::params![mid, sid], |row| row.get::<_, String>(0))
      .ok()
  })
  .await
  .ok()
  .flatten();

  let Some(issue_id) = issue_id else {
    tracing::debug!(
        component = "mission_control",
        event = "resume_hook.no_linked_issue",
        session_id = %session_id,
        mission_id = %mission_id,
        "No mission issue linked to resumed session"
    );
    return;
  };

  let _ = state
    .persist()
    .send(PersistCommand::MissionIssueUpdateState {
      mission_id: mission_id.to_string(),
      issue_id: issue_id.clone(),
      orchestration_state: "running".to_string(),
      session_id: Some(session_id.to_string()),
      workspace_id: None,
      attempt: None,
      last_error: Some(None),
      retry_due_at: None,
      started_at: Some(Some(now)),
      completed_at: Some(None),
    })
    .await;

  state.publish_mission_invalidation(mission_id);

  tracing::info!(
      component = "mission_control",
      event = "resume_hook.issue_reactivated",
      session_id = %session_id,
      mission_id = %mission_id,
      issue_id = %issue_id,
      "Reactivated mission issue on session resume"
  );
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
