use std::sync::Arc;

use orbitdock_protocol::SessionState;
use tracing::warn;

use crate::domain::sessions::conversation::{ConversationBootstrap, ConversationPage};
use crate::infrastructure::persistence::{
    load_message_page_for_session, load_messages_for_session, load_session_by_id,
    load_subagents_for_session,
};
use crate::runtime::conversation_policy::{
    conversation_page_from_rows, conversation_page_with_total, expected_page_row_count,
    prepend_conversation_page, requires_coherent_history_page, COHERENT_HISTORY_MAX_ROWS,
};
use crate::runtime::query_fallback_policy::{
    select_persisted_bootstrap_seed_source, select_persisted_raw_conversation_page_source,
    select_restored_full_session_history_source, select_runtime_bootstrap_seed_source,
    select_runtime_full_session_history_source, select_runtime_raw_conversation_page_source,
    BootstrapSeedSource, FullSessionHistorySource, RawConversationPageSource,
};
use crate::runtime::restored_sessions::{
    hydrate_restored_rows_if_missing, restored_session_to_state,
};
use crate::runtime::session_actor::SessionActorHandle;
use crate::runtime::session_registry::SessionRegistry;
use crate::runtime::session_runtime_helpers::{hydrate_full_row_history, merge_rows_by_sequence};

#[derive(Debug)]
pub(crate) enum SessionLoadError {
    NotFound,
    Db(String),
    Runtime(String),
}

async fn expand_conversation_page(
    state: &Arc<SessionRegistry>,
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
            state,
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

async fn top_up_runtime_page_from_db(
    session_id: &str,
    page: ConversationPage,
    before_sequence: Option<u64>,
    limit: usize,
) -> Result<ConversationPage, SessionLoadError> {
    if limit == 0 {
        return Ok(page);
    }

    if !runtime_page_requires_db_reconciliation(&page, before_sequence, limit) {
        return Ok(page);
    }

    let db_page = load_message_page_for_session(session_id, before_sequence, limit)
        .await
        .map_err(|err| SessionLoadError::Db(err.to_string()))?;
    if db_page.rows.is_empty() {
        return Ok(page);
    }

    let rows = merge_rows_by_sequence(db_page.rows, page.rows);
    let merged_count = rows.len() as u64;
    Ok(conversation_page_with_total(
        rows,
        page.total_row_count
            .max(db_page.total_count)
            .max(merged_count),
    ))
}

fn runtime_page_requires_db_reconciliation(
    page: &ConversationPage,
    before_sequence: Option<u64>,
    limit: usize,
) -> bool {
    let expected_count = expected_page_row_count(page.total_row_count, before_sequence, limit);
    if expected_count == 0 {
        return !page.rows.is_empty();
    }

    if page.rows.len() != expected_count {
        return true;
    }

    page_expected_window_is_contiguous(page, before_sequence, expected_count)
        .map(|is_contiguous| !is_contiguous)
        .unwrap_or(true)
}

fn page_expected_window_is_contiguous(
    page: &ConversationPage,
    before_sequence: Option<u64>,
    expected_count: usize,
) -> Option<bool> {
    let upper_bound = before_sequence
        .unwrap_or(page.total_row_count)
        .min(page.total_row_count);
    let expected_newest = upper_bound.checked_sub(1)?;
    let expected_oldest = expected_newest
        .checked_add(1)?
        .checked_sub(expected_count as u64)?;

    let sequences: Vec<u64> = page.rows.iter().map(|entry| entry.sequence).collect();
    let expected: Vec<u64> = (expected_oldest..=expected_newest).collect();
    Some(sequences == expected)
}

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
    state: &Arc<SessionRegistry>,
    session_id: &str,
    before_sequence: Option<u64>,
    limit: usize,
) -> Result<ConversationPage, SessionLoadError> {
    if let Some(actor) = state.get_session(session_id) {
        let page = actor
            .conversation_page(before_sequence, limit)
            .await
            .map_err(SessionLoadError::Runtime)?;
        let snapshot = actor.snapshot();
        match select_runtime_raw_conversation_page_source(
            !page.rows.is_empty() || page.total_row_count > 0,
            snapshot.transcript_path.is_some(),
        ) {
            RawConversationPageSource::RuntimePage => {
                return top_up_runtime_page_from_db(session_id, page, before_sequence, limit).await;
            }
            RawConversationPageSource::RuntimeTranscript => {
                if let Some(path) = snapshot.transcript_path.clone() {
                    if let Ok(Some(loaded)) = actor
                        .load_transcript_and_sync(path, session_id.to_string())
                        .await
                    {
                        return Ok(conversation_page_from_rows(
                            loaded.rows,
                            before_sequence,
                            limit,
                        ));
                    }
                }
            }
            RawConversationPageSource::DatabasePage
            | RawConversationPageSource::RestoredTranscript
            | RawConversationPageSource::RestoredMessages => {}
        }

        let db_page = load_message_page_for_session(session_id, before_sequence, limit)
            .await
            .map_err(|err| SessionLoadError::Db(err.to_string()))?;
        return Ok(conversation_page_from_db_page(
            db_page.rows,
            db_page.total_count,
        ));
    }

    match load_session_by_id(session_id).await {
        Ok(Some(mut restored)) => {
            let db_page = load_message_page_for_session(session_id, before_sequence, limit)
                .await
                .map_err(|err| SessionLoadError::Db(err.to_string()))?;
            match select_persisted_raw_conversation_page_source(
                !db_page.rows.is_empty() || db_page.total_count > 0,
                !restored.rows.is_empty(),
                restored.transcript_path.is_some(),
            ) {
                RawConversationPageSource::DatabasePage => {
                    return Ok(conversation_page_from_db_page(
                        db_page.rows,
                        db_page.total_count,
                    ));
                }
                RawConversationPageSource::RestoredTranscript => {
                    hydrate_restored_rows_if_missing(&mut restored, session_id).await;
                }
                RawConversationPageSource::RestoredMessages => {}
                RawConversationPageSource::RuntimePage
                | RawConversationPageSource::RuntimeTranscript => {}
            }

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

pub(crate) async fn load_conversation_page(
    state: &Arc<SessionRegistry>,
    session_id: &str,
    before_sequence: Option<u64>,
    limit: usize,
) -> Result<ConversationPage, SessionLoadError> {
    let page = load_raw_conversation_page(state, session_id, before_sequence, limit).await?;
    expand_conversation_page(state, session_id, page, limit).await
}

pub(crate) async fn load_conversation_bootstrap(
    state: &Arc<SessionRegistry>,
    session_id: &str,
    limit: usize,
) -> Result<ConversationBootstrap, SessionLoadError> {
    if let Some(actor) = state.get_session(session_id) {
        let mut bootstrap = actor
            .conversation_bootstrap(limit)
            .await
            .map_err(SessionLoadError::Runtime)?;

        match select_runtime_bootstrap_seed_source(
            !bootstrap.session.rows.is_empty() || bootstrap.total_row_count > 0,
            bootstrap.session.transcript_path.is_some(),
        ) {
            BootstrapSeedSource::RuntimeBootstrap => {}
            BootstrapSeedSource::RuntimeTranscript => {
                if let Some(path) = bootstrap.session.transcript_path.clone() {
                    if let Ok(Some(loaded)) = actor
                        .load_transcript_and_sync(path, session_id.to_string())
                        .await
                    {
                        let page = conversation_page_from_rows(loaded.rows.clone(), None, limit);
                        bootstrap.session = loaded;
                        bootstrap.session.rows = page.rows.clone();
                        bootstrap.total_row_count = page.total_row_count;
                        bootstrap.has_more_before = page.has_more_before;
                        bootstrap.oldest_sequence = page.oldest_sequence;
                        bootstrap.newest_sequence = page.newest_sequence;
                    }
                }
            }
            BootstrapSeedSource::DatabasePage => {
                let db_page = load_message_page_for_session(session_id, None, limit)
                    .await
                    .map_err(|err| SessionLoadError::Db(err.to_string()))?;
                bootstrap.session.rows = db_page.rows;
                bootstrap.total_row_count = db_page.total_count;
                bootstrap.has_more_before = bootstrap
                    .session
                    .rows
                    .first()
                    .map(|entry| entry.sequence)
                    .is_some_and(|sequence| sequence > 0);
                bootstrap.oldest_sequence =
                    bootstrap.session.rows.first().map(|entry| entry.sequence);
                bootstrap.newest_sequence =
                    bootstrap.session.rows.last().map(|entry| entry.sequence);
            }
            BootstrapSeedSource::RawConversationPage
            | BootstrapSeedSource::RestoredTranscript
            | BootstrapSeedSource::RestoredMessages => {}
        }

        let page = expand_conversation_page(
            state,
            session_id,
            top_up_runtime_page_from_db(
                session_id,
                ConversationPage {
                    rows: bootstrap.session.rows.clone(),
                    total_row_count: bootstrap.total_row_count,
                    has_more_before: bootstrap.has_more_before,
                    oldest_sequence: bootstrap.oldest_sequence,
                    newest_sequence: bootstrap.newest_sequence,
                },
                None,
                limit,
            )
            .await?,
            limit,
        )
        .await?;
        bootstrap.session.rows = page.rows.clone();
        bootstrap.session.total_row_count = page.total_row_count;
        bootstrap.session.has_more_before = page.has_more_before;
        bootstrap.session.oldest_sequence = page.oldest_sequence;
        bootstrap.session.newest_sequence = page.newest_sequence;
        bootstrap.total_row_count = page.total_row_count;
        bootstrap.has_more_before = page.has_more_before;
        bootstrap.oldest_sequence = page.oldest_sequence;
        bootstrap.newest_sequence = page.newest_sequence;

        hydrate_subagents(&mut bootstrap.session, session_id).await;
        return Ok(bootstrap);
    }

    match load_session_by_id(session_id).await {
        Ok(Some(mut restored)) => {
            let raw_page = load_raw_conversation_page(state, session_id, None, limit).await?;
            let page = match select_persisted_bootstrap_seed_source(
                !raw_page.rows.is_empty() || raw_page.total_row_count > 0,
                !restored.rows.is_empty(),
                restored.transcript_path.is_some(),
            ) {
                BootstrapSeedSource::RawConversationPage => raw_page,
                BootstrapSeedSource::RestoredTranscript => {
                    hydrate_restored_rows_if_missing(&mut restored, session_id).await;
                    conversation_page_from_rows(restored.rows.clone(), None, limit)
                }
                BootstrapSeedSource::RestoredMessages => {
                    conversation_page_from_rows(restored.rows.clone(), None, limit)
                }
                BootstrapSeedSource::RuntimeBootstrap
                | BootstrapSeedSource::RuntimeTranscript
                | BootstrapSeedSource::DatabasePage => raw_page,
            };
            let page = expand_conversation_page(state, session_id, page, limit).await?;

            let mut state = restored_session_to_state(restored);
            state.rows = page.rows.clone();
            hydrate_subagents(&mut state, session_id).await;
            Ok(ConversationBootstrap {
                session: state,
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

pub(crate) async fn load_full_session_state(
    state: &Arc<SessionRegistry>,
    session_id: &str,
    include_messages: bool,
) -> Result<SessionState, SessionLoadError> {
    if let Some(actor) = state.get_session(session_id) {
        let mut snapshot = actor
            .retained_state()
            .await
            .map_err(SessionLoadError::Runtime)?;

        if include_messages {
            hydrate_runtime_rows(&actor, &mut snapshot, session_id).await;
            snapshot.rows =
                hydrate_full_row_history(session_id, snapshot.rows, Some(snapshot.total_row_count))
                    .await;
            snapshot.total_row_count = snapshot.rows.len() as u64;
            snapshot.has_more_before = false;
            snapshot.oldest_sequence = snapshot.rows.first().map(|entry| entry.sequence);
            snapshot.newest_sequence = snapshot.rows.last().map(|entry| entry.sequence);
        } else {
            snapshot.rows.clear();
            snapshot.oldest_sequence = None;
            snapshot.newest_sequence = None;
        }
        hydrate_subagents(&mut snapshot, session_id).await;
        return Ok(snapshot);
    }

    match load_session_by_id(session_id).await {
        Ok(Some(mut restored)) => {
            if matches!(
                select_restored_full_session_history_source(
                    !restored.rows.is_empty(),
                    restored.transcript_path.is_some(),
                ),
                FullSessionHistorySource::Transcript
            ) {
                hydrate_restored_rows_if_missing(&mut restored, session_id).await;
            }

            let mut state = restored_session_to_state(restored);
            if !include_messages {
                state.rows.clear();
                state.oldest_sequence = None;
                state.newest_sequence = None;
            }
            hydrate_subagents(&mut state, session_id).await;
            Ok(state)
        }
        Ok(None) => Err(SessionLoadError::NotFound),
        Err(err) => Err(SessionLoadError::Db(err.to_string())),
    }
}

async fn hydrate_runtime_rows(
    actor: &SessionActorHandle,
    state: &mut SessionState,
    session_id: &str,
) {
    let runtime_limit = usize::try_from(state.total_row_count)
        .ok()
        .filter(|limit| *limit > 0)
        .unwrap_or(COHERENT_HISTORY_MAX_ROWS)
        .min(COHERENT_HISTORY_MAX_ROWS);

    loop {
        match select_runtime_full_session_history_source(
            !state.rows.is_empty(),
            state.transcript_path.is_some(),
        ) {
            FullSessionHistorySource::ExistingMessages => return,
            FullSessionHistorySource::Transcript => {
                if let Some(path) = state.transcript_path.clone() {
                    if let Ok(Some(loaded)) = actor
                        .load_transcript_and_sync(path, session_id.to_string())
                        .await
                    {
                        *state = loaded;
                        continue;
                    }
                }
            }
            FullSessionHistorySource::DatabaseMessages => {}
        }

        if let Ok(page) = actor.conversation_page(None, runtime_limit).await {
            if !page.rows.is_empty() {
                state.rows = page.rows;
                state.total_row_count = page.total_row_count;
                state.has_more_before = page.has_more_before;
                state.oldest_sequence = page.oldest_sequence;
                state.newest_sequence = page.newest_sequence;
                return;
            }
        }

        if let Ok(rows) = load_messages_for_session(session_id).await {
            if !rows.is_empty() {
                state.rows = rows;
            }
        }
        return;
    }
}

async fn hydrate_subagents(state: &mut SessionState, session_id: &str) {
    if !state.subagents.is_empty() {
        return;
    }

    match load_subagents_for_session(session_id).await {
        Ok(subagents) => {
            state.subagents = subagents;
        }
        Err(err) => {
            warn!(
                component = "api",
                event = "api.get_session.subagents_load_failed",
                session_id = %session_id,
                error = %err,
                "Failed to load session subagents"
            );
        }
    }
}
