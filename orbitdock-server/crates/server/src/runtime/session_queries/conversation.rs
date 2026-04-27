use std::sync::Arc;

use crate::domain::sessions::conversation::{ConversationBootstrap, ConversationPage};
use crate::infrastructure::persistence::{
  load_message_page_for_session, load_session_by_id, load_session_metadata_by_id, RestoredSession,
};
use crate::runtime::conversation_policy::{
  conversation_page_from_rows, prepend_conversation_page, requires_coherent_history_page,
  COHERENT_HISTORY_MAX_ROWS,
};
use crate::runtime::restored_sessions::restored_session_to_state;
use crate::runtime::session_registry::SessionRegistry;
use tracing::warn;

use super::detail::{
  apply_page_to_session, hydrate_ephemeral_state, hydrate_subagents, trim_session_payload,
};
use super::projection::SessionLoadError;

fn conversation_page_from_db_page(
  rows: Vec<orbitdock_protocol::conversation_contracts::ConversationRowEntry>,
  total_count: u64,
) -> ConversationPage {
  ConversationPage {
    has_more_before: rows
      .first()
      .map(|entry| entry.sequence)
      .is_some_and(|sequence| sequence > 0),
    oldest_sequence: rows.first().map(|entry| entry.sequence),
    newest_sequence: rows.last().map(|entry| entry.sequence),
    total_row_count: total_count,
    rows,
  }
}

async fn load_raw_conversation_page(
  session_id: &str,
  before_sequence: Option<u64>,
  limit: usize,
) -> Result<ConversationPage, SessionLoadError> {
  match load_message_page_for_session(session_id, before_sequence, limit).await {
    Ok(db_page) if !db_page.rows.is_empty() || db_page.total_count > 0 => {
      return Ok(conversation_page_from_db_page(
        db_page.rows,
        db_page.total_count,
      ));
    }
    Ok(_) => {}
    Err(err) => return Err(SessionLoadError::Db(err.to_string())),
  }

  let restored_result: Result<Option<RestoredSession>, anyhow::Error> =
    load_session_by_id(session_id).await;

  match restored_result {
    Ok(Some(mut restored)) => {
      crate::runtime::restored_sessions::hydrate_restored_rows_if_missing(
        &mut restored,
        session_id,
      )
      .await;
      Ok(conversation_page_from_rows(
        restored.rows,
        before_sequence,
        limit,
      ))
    }
    Ok(None) => Err(SessionLoadError::NotFound),
    Err(err) => Err(SessionLoadError::Db(err.to_string())),
  }
}

async fn expand_conversation_page(
  session_id: &str,
  mut page: ConversationPage,
  chunk_limit: usize,
) -> Result<ConversationPage, SessionLoadError> {
  let page_chunk_limit = chunk_limit.max(1);

  while requires_coherent_history_page(&page.rows, page.has_more_before)
    && page.rows.len() < COHERENT_HISTORY_MAX_ROWS
  {
    let Some(before_sequence) = page.oldest_sequence else {
      break;
    };
    let remaining = COHERENT_HISTORY_MAX_ROWS.saturating_sub(page.rows.len());
    if remaining == 0 {
      break;
    }

    let older = load_raw_conversation_page(
      session_id,
      Some(before_sequence),
      page_chunk_limit.min(remaining),
    )
    .await?;
    if older.rows.is_empty() {
      break;
    }

    let previous_len = page.rows.len();
    page = prepend_conversation_page(page, older);
    if page.rows.len() == previous_len {
      break;
    }
  }

  Ok(page)
}

pub(crate) async fn load_conversation_page(
  session_id: &str,
  before_sequence: Option<u64>,
  limit: usize,
) -> Result<ConversationPage, SessionLoadError> {
  let page = load_raw_conversation_page(session_id, before_sequence, limit).await?;
  expand_conversation_page(session_id, page, limit).await
}

pub(crate) async fn load_conversation_bootstrap(
  state: &Arc<SessionRegistry>,
  session_id: &str,
  limit: usize,
) -> Result<ConversationBootstrap, SessionLoadError> {
  if let Some(actor) = state.get_session(session_id) {
    if let (Ok(mut session), Ok(page)) = (
      actor.retained_state().await,
      actor.conversation_page(None, limit).await,
    ) {
      let page = expand_conversation_page(session_id, page, limit).await?;

      trim_session_payload(&mut session, true, false);
      apply_page_to_session(&mut session, &page);
      hydrate_subagents(&mut session, session_id).await;

      return Ok(ConversationBootstrap {
        session,
        total_row_count: page.total_row_count,
        has_more_before: page.has_more_before,
        oldest_sequence: page.oldest_sequence,
        newest_sequence: page.newest_sequence,
      });
    }

    warn!(
      component = "api",
      event = "api.get_conversation.runtime_state_unavailable",
      session_id = %session_id,
      "Falling back to persisted conversation bootstrap"
    );
  }

  let restored_result: Result<Option<RestoredSession>, anyhow::Error> =
    load_session_metadata_by_id(session_id).await;

  match restored_result {
    Ok(Some(restored)) => {
      let page = load_conversation_page(session_id, None, limit).await?;

      let mut session = restored_session_to_state(restored);
      trim_session_payload(&mut session, false, false);
      apply_page_to_session(&mut session, &page);
      hydrate_ephemeral_state(&mut session, state, session_id).await;
      hydrate_subagents(&mut session, session_id).await;

      Ok(ConversationBootstrap {
        session,
        total_row_count: page.total_row_count,
        has_more_before: page.has_more_before,
        oldest_sequence: page.oldest_sequence,
        newest_sequence: page.newest_sequence,
      })
    }
    Ok(None) => Err(SessionLoadError::NotFound),
    Err(err) => Err(SessionLoadError::Db(err.to_string())),
  }
}
