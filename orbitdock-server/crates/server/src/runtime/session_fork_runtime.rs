use std::sync::Arc;

use tracing::{debug, info, warn};

use orbitdock_connector_codex::CodexConnector;
use orbitdock_protocol::{
    ClaudeIntegrationMode, CodexIntegrationMode, Provider, SessionState, SessionSummary,
};

use crate::connectors::claude_session::ClaudeSession;
use crate::connectors::codex_session::CodexSession;
use crate::domain::sessions::session::SessionHandle;
use crate::infrastructure::persistence::{load_messages_from_transcript_path, PersistCommand};
use crate::runtime::session_fork_policy::{
    remap_messages_for_fork, select_fork_messages, truncate_messages_before_nth_user_message,
};
use crate::runtime::session_registry::SessionRegistry;
use crate::runtime::session_runtime_helpers::{
    claim_codex_thread_for_direct_session, hydrate_full_message_history,
};

pub(crate) struct ForkedSessionStart {
    pub new_session_id: String,
    pub summary: SessionSummary,
    pub snapshot: SessionState,
    pub forked_from_thread_id: Option<String>,
}

pub(crate) struct FinalizeCodexForkRequest<'a> {
    pub source_session_id: &'a str,
    pub nth_user_message: Option<u32>,
    pub effective_cwd: &'a str,
    pub effective_model: Option<&'a str>,
    pub effective_approval_policy: Option<&'a str>,
    pub effective_sandbox_mode: Option<&'a str>,
    pub new_connector: CodexConnector,
    pub new_thread_id: String,
}

pub(crate) async fn start_claude_fork_session(
    state: &Arc<SessionRegistry>,
    source_session_id: &str,
    effective_cwd: &str,
    effective_model: Option<&str>,
    permission_mode: Option<&str>,
    allowed_tools: &[String],
    disallowed_tools: &[String],
) -> Result<ForkedSessionStart, String> {
    let new_session_id = orbitdock_protocol::new_id();
    let project_name = effective_cwd.split('/').next_back().map(String::from);
    let fork_branch = crate::domain::git::repo::resolve_git_branch(effective_cwd).await;

    let claude_session = ClaudeSession::new(
        new_session_id.clone(),
        effective_cwd,
        effective_model,
        None,
        permission_mode,
        allowed_tools,
        disallowed_tools,
        None,
    )
    .await
    .map_err(|error| error.to_string())?;

    let mut handle = SessionHandle::new(
        new_session_id.clone(),
        Provider::Claude,
        effective_cwd.to_string(),
    );
    handle.set_git_branch(fork_branch.clone());
    handle.set_claude_integration_mode(Some(ClaudeIntegrationMode::Direct));
    handle.set_forked_from(source_session_id.to_string());
    if let Some(model) = effective_model {
        handle.set_model(Some(model.to_string()));
    }

    let summary = handle.summary();
    let snapshot = handle.retained_state();
    let persist_tx = state.persist().clone();

    let _ = persist_tx
        .send(PersistCommand::SessionCreate {
            id: new_session_id.clone(),
            provider: Provider::Claude,
            project_path: effective_cwd.to_string(),
            project_name,
            branch: fork_branch,
            model: effective_model.map(ToOwned::to_owned),
            approval_policy: None,
            sandbox_mode: None,
            permission_mode: permission_mode.map(ToOwned::to_owned),
            forked_from_session_id: Some(source_session_id.to_string()),
        })
        .await;

    handle.set_list_tx(state.list_tx());
    let (actor_handle, action_tx) = crate::connectors::claude_session::start_event_loop(
        claude_session,
        handle,
        persist_tx,
        state.list_tx(),
        state.clone(),
    );
    state.add_session_actor(actor_handle);
    state.set_claude_action_tx(&new_session_id, action_tx);

    Ok(ForkedSessionStart {
        new_session_id,
        summary,
        snapshot,
        forked_from_thread_id: None,
    })
}

pub(crate) async fn finalize_codex_fork_session(
    state: &Arc<SessionRegistry>,
    request: FinalizeCodexForkRequest<'_>,
) -> Result<ForkedSessionStart, String> {
    let FinalizeCodexForkRequest {
        source_session_id,
        nth_user_message,
        effective_cwd,
        effective_model,
        effective_approval_policy,
        effective_sandbox_mode,
        new_connector,
        new_thread_id,
    } = request;
    let new_session_id = orbitdock_protocol::new_id();
    let project_name = effective_cwd.split('/').next_back().map(String::from);
    let fork_branch = crate::domain::git::repo::resolve_git_branch(effective_cwd).await;

    let mut handle = SessionHandle::new(
        new_session_id.clone(),
        Provider::Codex,
        effective_cwd.to_string(),
    );
    handle.set_git_branch(fork_branch.clone());
    handle.set_codex_integration_mode(Some(CodexIntegrationMode::Direct));
    handle.set_config(
        effective_approval_policy.map(ToOwned::to_owned),
        effective_sandbox_mode.map(ToOwned::to_owned),
    );
    handle.set_forked_from(source_session_id.to_string());

    let source_fork_messages =
        load_source_fork_messages(state, source_session_id, nth_user_message, &new_session_id)
            .await;
    let rollout_messages = load_rollout_fork_messages(&new_connector, &new_session_id).await;

    if !source_fork_messages.is_empty() && rollout_messages.len() < source_fork_messages.len() {
        info!(
            component = "session",
            event = "session.fork.messages_source_selected",
            new_session_id = %new_session_id,
            source_message_count = source_fork_messages.len(),
            rollout_message_count = rollout_messages.len(),
            "Selected source session messages for fork hydration"
        );
    }

    let forked_messages = select_fork_messages(source_fork_messages, rollout_messages);
    if !forked_messages.is_empty() {
        handle.replace_messages(forked_messages.clone());
    }

    let summary = handle.summary();
    let snapshot = handle.retained_state();
    let persist_tx = state.persist().clone();

    let _ = persist_tx
        .send(PersistCommand::SessionCreate {
            id: new_session_id.clone(),
            provider: Provider::Codex,
            project_path: effective_cwd.to_string(),
            project_name,
            branch: fork_branch,
            model: effective_model.map(ToOwned::to_owned),
            approval_policy: effective_approval_policy.map(ToOwned::to_owned),
            sandbox_mode: effective_sandbox_mode.map(ToOwned::to_owned),
            permission_mode: None,
            forked_from_session_id: Some(source_session_id.to_string()),
        })
        .await;

    for message in forked_messages {
        let _ = persist_tx
            .send(PersistCommand::MessageAppend {
                session_id: new_session_id.clone(),
                message,
            })
            .await;
    }

    claim_codex_thread_for_direct_session(
        state,
        &persist_tx,
        &new_session_id,
        &new_thread_id,
        "legacy_codex_thread_row_cleanup",
    )
    .await;

    let codex_session = CodexSession {
        session_id: new_session_id.clone(),
        connector: new_connector,
    };
    handle.set_list_tx(state.list_tx());
    let (actor_handle, action_tx) = crate::connectors::codex_session::start_event_loop(
        codex_session,
        handle,
        persist_tx,
        state.clone(),
    );
    state.add_session_actor(actor_handle);
    state.set_codex_action_tx(&new_session_id, action_tx);

    Ok(ForkedSessionStart {
        new_session_id,
        summary,
        snapshot,
        forked_from_thread_id: Some(new_thread_id),
    })
}

async fn load_source_fork_messages(
    state: &Arc<SessionRegistry>,
    source_session_id: &str,
    nth_user_message: Option<u32>,
    new_session_id: &str,
) -> Vec<orbitdock_protocol::Message> {
    let Some(source_actor) = state.get_session(source_session_id) else {
        return Vec::new();
    };

    match source_actor.retained_state().await {
        Ok(source_state) => {
            let full_source_messages = hydrate_full_message_history(
                source_session_id,
                source_state.messages,
                source_state.total_message_count,
            )
            .await;
            remap_messages_for_fork(
                truncate_messages_before_nth_user_message(&full_source_messages, nth_user_message),
                new_session_id,
            )
        }
        Err(_) => {
            warn!(
                component = "session",
                event = "session.fork.source_state_unavailable",
                source_session_id = %source_session_id,
                new_session_id = %new_session_id,
                "Failed to read source session state for fork hydration"
            );
            Vec::new()
        }
    }
}

async fn load_rollout_fork_messages(
    connector: &CodexConnector,
    new_session_id: &str,
) -> Vec<orbitdock_protocol::Message> {
    let Some(rollout_path) = connector.rollout_path().await else {
        return Vec::new();
    };

    match load_messages_from_transcript_path(&rollout_path, new_session_id).await {
        Ok(messages) if !messages.is_empty() => {
            info!(
                component = "session",
                event = "session.fork.messages_loaded",
                new_session_id = %new_session_id,
                message_count = messages.len(),
                "Loaded forked conversation history"
            );
            messages
        }
        Ok(_) => {
            debug!(
                component = "session",
                event = "session.fork.no_messages",
                new_session_id = %new_session_id,
                "Forked thread rollout has no parseable messages"
            );
            Vec::new()
        }
        Err(error) => {
            warn!(
                component = "session",
                event = "session.fork.messages_load_failed",
                new_session_id = %new_session_id,
                error = %error,
                "Failed to load forked conversation history"
            );
            Vec::new()
        }
    }
}
