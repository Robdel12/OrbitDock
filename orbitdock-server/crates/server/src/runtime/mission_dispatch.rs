//! Per-issue dispatch: orchestrate state transitions and delegate to the
//! workspace provider for workspace setup, session creation, and prompt
//! delivery.

use std::sync::Arc;

use tracing::{info, warn};

use crate::domain::mission_control::config::AgentConfig;
use crate::domain::mission_control::prompt::{render_prompt, IssueContext};
use crate::domain::mission_control::tracker::{Tracker, TrackerIssue};
use crate::infrastructure::persistence::mission_control::{
    update_mission_issue_state_sync, MissionIssueStateUpdate,
};
use crate::runtime::session_registry::SessionRegistry;
use crate::runtime::workspace_dispatch::{
    build_workspace_provider, DispatchRequest, WorkspaceIssueRef,
};

/// Mission-level configuration shared across all issue dispatches.
pub struct DispatchContext {
    pub repo_root: String,
    pub prompt_template: String,
    pub base_branch: String,
    pub agent_config: AgentConfig,
    pub worktree_root_dir: Option<String>,
    pub state_on_dispatch: String,
    pub tracker: Arc<dyn Tracker>,
}

/// Dispatch a single issue: manage state transitions and delegate workspace
/// provisioning + agent startup to the workspace provider.
pub async fn dispatch_issue(
    registry: &Arc<SessionRegistry>,
    mission_id: &str,
    issue: &TrackerIssue,
    provider_str: &str,
    ctx: &DispatchContext,
    attempt: u32,
) -> anyhow::Result<()> {
    info!(
        component = "mission_control",
        event = "dispatch.start",
        mission_id = %mission_id,
        issue_id = %issue.id,
        issue_identifier = %issue.identifier,
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
            &conn,
            &mid,
            &iid,
            &MissionIssueStateUpdate {
                orchestration_state: "claimed",
                session_id: None,
                attempt: None,
                last_error: Some(None),
                started_at: Some(Some(&now)),
                completed_at: None,
            },
        )
        .ok()
    })
    .await;

    // Best-effort: move issue to configured dispatch state in tracker
    if let Err(err) = ctx
        .tracker
        .update_issue_state(&issue.id, &ctx.state_on_dispatch)
        .await
    {
        warn!(
            component = "mission_control",
            event = "dispatch.tracker_write_failed",
            issue_id = %issue.id,
            target_state = %ctx.state_on_dispatch,
            error = %err,
            "Failed to update issue state in tracker"
        );
    }

    // Render prompt
    let issue_ctx = IssueContext {
        issue_id: &issue.id,
        issue_identifier: &issue.identifier,
        issue_title: &issue.title,
        issue_description: issue.description.as_deref(),
        issue_url: issue.url.as_deref(),
        issue_state: Some(&issue.state),
        issue_labels: &issue.labels,
    };
    let prompt = render_prompt(&ctx.prompt_template, &issue_ctx, attempt)?;

    // Delegate workspace provisioning + agent startup to the provider
    let tracker_kind = ctx.tracker.kind().to_string();
    let dispatch_request = DispatchRequest {
        repo_root: ctx.repo_root.clone(),
        issue: WorkspaceIssueRef {
            id: issue.id.clone(),
            identifier: issue.identifier.clone(),
        },
        base_branch: ctx.base_branch.clone(),
        worktree_root_dir: ctx.worktree_root_dir.clone(),
        mission_id: mission_id.to_string(),
        tracker_kind: tracker_kind.clone(),
        tracker_api_key: crate::support::api_keys::resolve_tracker_api_key_for_mission(
            mission_id,
            &tracker_kind,
        ),
        provider_str: provider_str.to_string(),
        agent_config: ctx.agent_config.clone(),
        prompt,
        registry: registry.clone(),
    };

    // Resolve the provider at dispatch time so runtime config changes take
    // effect on the next launched issue rather than after an outer loop ends.
    let workspace_provider = build_workspace_provider(registry.workspace_provider_kind())?;

    let result = match workspace_provider.dispatch(&dispatch_request).await {
        Ok(r) => r,
        Err(err) => {
            warn!(
                component = "mission_control",
                event = "dispatch.workspace_failed",
                mission_id = %mission_id,
                issue_id = %issue.id,
                error = %err,
                "Workspace dispatch failed, marking issue as failed"
            );
            let db_path = registry.db_path().clone();
            let mid = mission_id.to_string();
            let iid = issue.id.clone();
            let err_msg = err.to_string();
            let now = chrono::Utc::now().to_rfc3339();
            let _ = tokio::task::spawn_blocking(move || {
                let conn = rusqlite::Connection::open(&db_path).ok()?;
                update_mission_issue_state_sync(
                    &conn,
                    &mid,
                    &iid,
                    &MissionIssueStateUpdate {
                        orchestration_state: "failed",
                        session_id: None,
                        attempt: Some(attempt),
                        last_error: Some(Some(&err_msg)),
                        started_at: None,
                        completed_at: Some(Some(&now)),
                    },
                )
                .ok()
            })
            .await;
            return Err(anyhow::anyhow!("{err}"));
        }
    };

    // Update mission issue with session link (synchronous)
    let db_path = registry.db_path().clone();
    let mid = mission_id.to_string();
    let iid = issue.id.clone();
    let sid = result.session_id.clone();
    let _ = tokio::task::spawn_blocking(move || {
        let conn = rusqlite::Connection::open(&db_path).ok()?;
        update_mission_issue_state_sync(
            &conn,
            &mid,
            &iid,
            &MissionIssueStateUpdate {
                orchestration_state: "running",
                session_id: Some(&sid),
                attempt: Some(attempt),
                last_error: Some(None),
                started_at: None,
                completed_at: None,
            },
        )
        .ok()
    })
    .await;

    info!(
        component = "mission_control",
        event = "dispatch.complete",
        mission_id = %mission_id,
        issue_id = %issue.id,
        session_id = %result.session_id,
        "Issue dispatched to session"
    );

    Ok(())
}
