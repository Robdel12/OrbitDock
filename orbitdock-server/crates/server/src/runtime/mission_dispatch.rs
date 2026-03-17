//! Per-issue dispatch: create worktree -> create session -> send prompt.

use std::sync::Arc;

use orbitdock_protocol::Provider;
use tracing::{info, warn};

use crate::connectors::claude_session::ClaudeAction;
use crate::connectors::codex_session::CodexAction;
use crate::domain::mission_control::config::AgentConfig;
use crate::domain::mission_control::prompt::render_prompt;
use crate::domain::mission_control::tracker::TrackerIssue;
use crate::infrastructure::persistence::mission_control::update_mission_issue_state_sync;
use crate::runtime::session_creation::{
    launch_prepared_direct_session, prepare_persist_direct_session, DirectSessionRequest,
};
use crate::runtime::session_registry::SessionRegistry;

/// Dispatch a single issue: create worktree, create session, send prompt.
#[allow(clippy::too_many_arguments)]
pub async fn dispatch_issue(
    registry: &Arc<SessionRegistry>,
    mission_id: &str,
    issue: &TrackerIssue,
    provider_str: &str,
    repo_root: &str,
    prompt_template: &str,
    base_branch: &str,
    agent_config: &AgentConfig,
    attempt: u32,
    worktree_root_dir: Option<&str>,
) -> anyhow::Result<()> {
    let branch_name = format!(
        "mission/{}",
        issue.identifier.to_lowercase().replace([' ', '/'], "-")
    );

    info!(
        component = "mission_control",
        event = "dispatch.start",
        mission_id = %mission_id,
        issue_id = %issue.id,
        issue_identifier = %issue.identifier,
        branch = %branch_name,
        attempt = attempt,
        "Dispatching issue"
    );

    // Update orchestration state to claimed (synchronous — must be visible before broadcast)
    let db_path = registry.db_path().clone();
    let mid = mission_id.to_string();
    let iid = issue.id.clone();
    let now = chrono::Utc::now().to_rfc3339();
    let _ = tokio::task::spawn_blocking(move || {
        let conn = rusqlite::Connection::open(&db_path).ok()?;
        update_mission_issue_state_sync(
            &conn, &mid, &iid, "claimed",
            None, None, Some(None), Some(Some(&now)), None,
        ).ok()
    })
    .await;

    // Create worktree via the runtime helper (also persists the record)
    let worktree_path = match crate::runtime::worktree_creation::create_tracked_worktree(
        registry,
        repo_root,
        &branch_name,
        Some(base_branch),
        orbitdock_protocol::WorktreeOrigin::Agent,
        worktree_root_dir,
        attempt == 1, // clean up stale worktrees on first attempt only
    )
    .await
    {
        Ok(summary) => summary.worktree_path,
        Err(err) => {
            warn!(
                component = "mission_control",
                event = "dispatch.worktree_failed",
                mission_id = %mission_id,
                issue_id = %issue.id,
                error = %err,
                "Worktree creation failed, marking issue as failed"
            );
            let db_path = registry.db_path().clone();
            let mid = mission_id.to_string();
            let iid = issue.id.clone();
            let err_msg = format!("Worktree creation failed: {err}");
            let now = chrono::Utc::now().to_rfc3339();
            let _ = tokio::task::spawn_blocking(move || {
                let conn = rusqlite::Connection::open(&db_path).ok()?;
                update_mission_issue_state_sync(
                    &conn, &mid, &iid, "failed",
                    None, Some(attempt), Some(Some(&err_msg)),
                    None, Some(Some(&now)),
                ).ok()
            })
            .await;
            return Err(anyhow::anyhow!("Worktree creation failed: {err}"));
        }
    };

    // Render prompt
    let prompt = render_prompt(
        prompt_template,
        &issue.id,
        &issue.identifier,
        &issue.title,
        issue.description.as_deref(),
        issue.url.as_deref(),
        Some(&issue.state),
        &issue.labels,
        attempt,
    )?;

    // Create session
    let provider: Provider = provider_str.parse().unwrap();

    // Resolve agent settings for the chosen provider
    let resolved = agent_config.resolve_for_provider(provider_str);

    let session_id = orbitdock_protocol::new_id();
    let request = DirectSessionRequest {
        provider,
        cwd: worktree_path,
        model: resolved.model.clone(),
        approval_policy: resolved.approval_policy,
        sandbox_mode: resolved.sandbox_mode,
        permission_mode: resolved.permission_mode,
        allowed_tools: resolved.allowed_tools,
        disallowed_tools: resolved.disallowed_tools,
        effort: resolved.effort.clone(),
        collaboration_mode: resolved.collaboration_mode,
        multi_agent: resolved.multi_agent,
        personality: resolved.personality,
        service_tier: resolved.service_tier,
        developer_instructions: resolved.developer_instructions,
    };

    let persisted = prepare_persist_direct_session(registry, session_id.clone(), request).await;
    launch_prepared_direct_session(registry, persisted)
        .await
        .map_err(|e| anyhow::anyhow!("Failed to launch session: {e}"))?;

    // Update mission issue with session link (synchronous)
    let db_path = registry.db_path().clone();
    let mid = mission_id.to_string();
    let iid = issue.id.clone();
    let sid = session_id.clone();
    let _ = tokio::task::spawn_blocking(move || {
        let conn = rusqlite::Connection::open(&db_path).ok()?;
        update_mission_issue_state_sync(
            &conn, &mid, &iid, "running",
            Some(&sid), Some(attempt), Some(None),
            None, None,
        ).ok()
    })
    .await;

    // Send the prompt as the first message via the connector action channel
    match provider {
        Provider::Codex => {
            if let Some(tx) = registry.get_codex_action_tx(&session_id) {
                let _ = tx
                    .send(CodexAction::SendMessage {
                        content: prompt,
                        model: resolved.model,
                        effort: resolved.effort,
                        skills: vec![],
                        images: vec![],
                        mentions: vec![],
                    })
                    .await;
            }
        }
        Provider::Claude => {
            if let Some(tx) = registry.get_claude_action_tx(&session_id) {
                let _ = tx
                    .send(ClaudeAction::SendMessage {
                        content: prompt,
                        model: resolved.model,
                        effort: resolved.effort,
                        images: vec![],
                    })
                    .await;
            }
        }
    }

    info!(
        component = "mission_control",
        event = "dispatch.complete",
        mission_id = %mission_id,
        issue_id = %issue.id,
        session_id = %session_id,
        "Issue dispatched to session"
    );

    Ok(())
}
