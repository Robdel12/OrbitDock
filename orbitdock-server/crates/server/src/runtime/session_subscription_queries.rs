use tracing::warn;

use orbitdock_protocol::SessionState;

use crate::infrastructure::persistence::{
    load_messages_for_session, load_session_by_id, load_subagents_for_session,
};
use crate::runtime::restored_sessions::{
    hydrate_restored_rows_if_missing, restored_session_to_state,
};
use crate::runtime::session_actor::SessionActorHandle;

pub(crate) async fn load_persisted_subscribe_state(
    session_id: &str,
) -> Result<Option<SessionState>, String> {
    match load_session_by_id(session_id).await {
        Ok(Some(mut restored)) => {
            hydrate_restored_rows_if_missing(&mut restored, session_id).await;
            let mut state = restored_session_to_state(restored);
            hydrate_subagents(&mut state, session_id, "session.subscribe").await;
            Ok(Some(state))
        }
        Ok(None) => Ok(None),
        Err(error) => Err(error.to_string()),
    }
}

pub(crate) async fn hydrate_runtime_subscribe_snapshot(
    actor: &SessionActorHandle,
    mut state: SessionState,
    session_id: &str,
) -> SessionState {
    loop {
        if !state.rows.is_empty() {
            break;
        }

        let Some(path) = state.transcript_path.clone() else {
            break;
        };
        match actor
            .load_transcript_and_sync(path, session_id.to_string())
            .await
        {
            Ok(Some(loaded)) => {
                state = loaded;
                continue;
            }
            Ok(None) | Err(_) => break,
        }
    }

    if state.rows.is_empty() {
        if let Ok(rows) = load_messages_for_session(session_id).await {
            if !rows.is_empty() {
                state.rows = rows;
            }
        }
    }

    state.total_row_count = state.rows.len() as u64;
    state.has_more_before = false;
    state.oldest_sequence = state.rows.first().map(|entry| entry.sequence);
    state.newest_sequence = state.rows.last().map(|entry| entry.sequence);

    hydrate_subagents(&mut state, session_id, "session.subscribe").await;
    state
}

pub(crate) async fn hydrate_subagents(
    state: &mut SessionState,
    session_id: &str,
    event: &'static str,
) {
    if !state.subagents.is_empty() {
        return;
    }

    match load_subagents_for_session(session_id).await {
        Ok(subagents) => {
            state.subagents = subagents;
        }
        Err(error) => {
            warn!(
                component = "runtime",
                event,
                session_id = %session_id,
                error = %error,
                "Failed to load session subagents"
            );
        }
    }
}
