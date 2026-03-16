//! Per-issue dispatch: create worktree -> create session -> send prompt.

use std::sync::Arc;

use orbitdock_protocol::Provider;
use tracing::{info, warn};

use crate::connectors::claude_session::ClaudeAction;
use crate::connectors::codex_session::CodexAction;
use crate::domain::mission_control::prompt::render_prompt;
use crate::domain::mission_control::tracker::TrackerIssue;
use crate::infrastructure::persistence::PersistCommand;
use crate::runtime::session_creation::{
    launch_prepared_direct_session, prepare_persist_direct_session, DirectSessionRequest,
};
use crate::runtime::session_registry::SessionRegistry;

/// Dispatch a single issue: create worktree, create session, send prompt.
pub async fn dispatch_issue(
    registry: &Arc<SessionRegistry>,
    mission_id: &str,
    issue: &TrackerIssue,
    provider_str: &str,
    repo_root: &str,
    prompt_template: &str,
    base_branch: &str,
) -> anyhow::Result<()> {
    let branch_name = format!(
        "mission/{}",
        issue
            .identifier
            .to_lowercase()
            .replace([' ', '/'], "-")
    );

    info!(
        component = "mission_control",
        event = "dispatch.start",
        mission_id = %mission_id,
        issue_id = %issue.id,
        issue_identifier = %issue.identifier,
        branch = %branch_name,
        "Dispatching issue"
    );

    // Update orchestration state to claimed
    let issue_row_id = orbitdock_protocol::new_id();
    let _ = registry
        .persist()
        .send(PersistCommand::MissionIssueUpdateState {
            id: issue_row_id.clone(),
            orchestration_state: "claimed".to_string(),
            session_id: None,
            attempt: None,
            last_error: Some(None),
            retry_due_at: None,
            started_at: Some(Some(chrono::Utc::now().to_rfc3339())),
            completed_at: None,
        })
        .await;

    // Create worktree via the runtime helper (also persists the record)
    let worktree_path = match crate::runtime::worktree_creation::create_tracked_worktree(
        registry,
        repo_root,
        &branch_name,
        Some(base_branch),
        orbitdock_protocol::WorktreeOrigin::Agent,
    )
    .await
    {
        Ok(summary) => summary.worktree_path,
        Err(err) => {
            warn!(
                component = "mission_control",
                event = "dispatch.worktree_failed",
                issue_id = %issue.id,
                error = %err,
                "Worktree creation failed, using repo root"
            );
            repo_root.to_string()
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
        1,
    )?;

    // Create session
    let provider = match provider_str {
        "codex" => Provider::Codex,
        _ => Provider::Claude,
    };

    let session_id = orbitdock_protocol::new_id();
    let request = DirectSessionRequest {
        provider,
        cwd: worktree_path,
        model: None,
        approval_policy: None,
        sandbox_mode: None,
        permission_mode: None,
        allowed_tools: vec![],
        disallowed_tools: vec![],
        effort: None,
        collaboration_mode: None,
        multi_agent: None,
        personality: None,
        service_tier: None,
        developer_instructions: None,
    };

    let persisted = prepare_persist_direct_session(registry, session_id.clone(), request).await;
    launch_prepared_direct_session(registry, persisted)
        .await
        .map_err(|e| anyhow::anyhow!("Failed to launch session: {e}"))?;

    // Update mission issue with session link
    let _ = registry
        .persist()
        .send(PersistCommand::MissionIssueUpdateState {
            id: issue_row_id,
            orchestration_state: "running".to_string(),
            session_id: Some(session_id.clone()),
            attempt: Some(1),
            last_error: Some(None),
            retry_due_at: None,
            started_at: None,
            completed_at: None,
        })
        .await;

    // Send the prompt as the first message via the connector action channel
    match provider {
        Provider::Codex => {
            if let Some(tx) = registry.get_codex_action_tx(&session_id) {
                let _ = tx
                    .send(CodexAction::SendMessage {
                        content: prompt,
                        model: None,
                        effort: None,
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
                        model: None,
                        effort: None,
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
