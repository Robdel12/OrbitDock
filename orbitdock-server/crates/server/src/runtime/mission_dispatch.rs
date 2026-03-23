//! Per-issue dispatch: create worktree -> create session -> send prompt.

use std::sync::Arc;

use orbitdock_protocol::Provider;
use tracing::{info, warn};

use crate::connectors::claude_session::ClaudeAction;
use crate::connectors::codex_session::CodexAction;
use crate::domain::mission_control::config::AgentConfig;
use crate::domain::mission_control::prompt::{render_prompt, IssueContext};
use crate::domain::mission_control::skills::{read_skill_content_for_claude, resolve_skill_inputs};
use crate::domain::mission_control::tracker::{Tracker, TrackerIssue};
use crate::infrastructure::persistence::mission_control::{
    update_mission_issue_state_sync, MissionIssueStateUpdate,
};
use crate::runtime::session_creation::{
    launch_prepared_direct_session, prepare_persist_direct_session, DirectSessionRequest,
};
use crate::runtime::session_registry::SessionRegistry;

/// Mission-level configuration shared across all issue dispatches.
pub struct DispatchContext {
    pub repo_root: String,
    pub prompt_template: String,
    pub base_branch: String,
    pub agent_config: AgentConfig,
    pub worktree_root_dir: Option<String>,
    pub state_on_dispatch: String,
}

/// Dispatch a single issue: create worktree, create session, send prompt.
pub async fn dispatch_issue(
    registry: &Arc<SessionRegistry>,
    mission_id: &str,
    issue: &TrackerIssue,
    provider_str: &str,
    ctx: &DispatchContext,
    attempt: u32,
    tracker: &Arc<dyn Tracker>,
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
    if let Err(err) = tracker
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

    // Fetch latest refs so the worktree starts from the current remote HEAD
    if let Err(err) = crate::domain::git::repo::fetch_origin(&ctx.repo_root).await {
        warn!(
            component = "mission_control",
            event = "dispatch.fetch_failed",
            mission_id = %mission_id,
            issue_id = %issue.id,
            error = %err,
            "git fetch origin failed — worktree will use local state"
        );
    }

    // Use origin/<base_branch> so the worktree is based on the freshly-fetched remote ref
    let remote_base = format!("origin/{}", ctx.base_branch);

    // Create worktree via the runtime helper (also persists the record)
    let worktree_path = match crate::runtime::worktree_creation::create_tracked_worktree(
        registry,
        &ctx.repo_root,
        &branch_name,
        Some(&remote_base),
        orbitdock_protocol::WorktreeOrigin::Agent,
        ctx.worktree_root_dir.as_deref(),
        true, // always clean up stale worktrees — if we're dispatching, no active session owns them
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
            return Err(anyhow::anyhow!("Worktree creation failed: {err}"));
        }
    };

    // Write .mcp.json for mission tools (Claude auto-discovers this at startup)
    let tracker_kind = tracker.kind();
    let api_key_for_mcp = crate::support::api_keys::resolve_tracker_api_key(tracker_kind);
    if let Some(api_key_value) = api_key_for_mcp {
        let (api_key_env, tracker_kind_str) = match tracker_kind {
            "github" => ("GITHUB_TOKEN", "github"),
            _ => ("LINEAR_API_KEY", "linear"),
        };

        let orbitdock_bin = std::env::current_exe()
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_else(|_| "orbitdock".to_string());

        let mcp_config = serde_json::json!({
            "mcpServers": {
                "orbitdock-mission": {
                    "command": orbitdock_bin,
                    "args": ["mcp-mission-tools"],
                    "env": {
                        api_key_env: api_key_value,
                        "ORBITDOCK_TRACKER_KIND": tracker_kind_str,
                        "ORBITDOCK_ISSUE_ID": issue.id,
                        "ORBITDOCK_ISSUE_IDENTIFIER": issue.identifier,
                        "ORBITDOCK_MISSION_ID": mission_id,
                    }
                }
            }
        });

        let mcp_path = format!("{worktree_path}/.mcp.json");
        if let Err(err) = tokio::fs::write(
            &mcp_path,
            serde_json::to_string_pretty(&mcp_config).unwrap_or_default(),
        )
        .await
        {
            warn!(
                component = "mission_control",
                event = "dispatch.mcp_write_failed",
                worktree_path = %worktree_path,
                error = %err,
                "Failed to write .mcp.json for mission tools; continuing without"
            );
        }
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

    // Create session
    let provider: Provider = match provider_str.parse() {
        Ok(p) => p,
        Err(_) => {
            warn!(
                component = "mission_control",
                event = "dispatch.invalid_provider",
                mission_id = %mission_id,
                issue_id = %issue.id,
                provider = %provider_str,
                "Invalid provider string, marking issue as failed"
            );
            let db_path = registry.db_path().clone();
            let mid = mission_id.to_string();
            let iid = issue.id.clone();
            let err_msg = format!("Invalid mission provider: {provider_str}");
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
            return Err(anyhow::anyhow!("Invalid mission provider: {provider_str}"));
        }
    };

    // Resolve agent settings for the chosen provider
    let resolved = ctx.agent_config.resolve_for_provider(provider_str);

    // Merge OrbitDock CLI + mission-specific instructions into developer_instructions
    let cli_ref = crate::domain::instructions::orbitdock_system_instructions();
    let mission_ref = crate::domain::instructions::mission_agent_instructions();
    let orbitdock_instructions = format!("{cli_ref}\n\n{mission_ref}");
    let developer_instructions = match resolved.developer_instructions {
        Some(ref existing) => Some(format!("{existing}\n\n{orbitdock_instructions}")),
        None => Some(orbitdock_instructions),
    };

    // Build dynamic tool specs for Codex sessions
    let dynamic_tools: Vec<codex_protocol::dynamic_tools::DynamicToolSpec> =
        crate::domain::mission_control::tools::mission_tool_definitions()
            .into_iter()
            .map(|t| codex_protocol::dynamic_tools::DynamicToolSpec {
                name: t.name,
                description: t.description,
                input_schema: t.input_schema,
                defer_loading: false,
            })
            .collect();

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
        developer_instructions,
        mission_id: Some(mission_id.to_string()),
        issue_identifier: Some(issue.identifier.clone()),
        dynamic_tools,
        allow_bypass_permissions: resolved.allow_bypass_permissions,
        codex_config_mode: None,
        codex_config_profile: None,
        codex_model_provider: None,
        codex_config_source: None,
        codex_config_overrides: None,
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

    // Send the prompt as the first message via the connector action channel
    match provider {
        Provider::Codex => {
            // Codex: resolve skill names to SkillInput values and attach natively
            let mission_skills = resolve_skill_inputs(&resolved.skills);
            if let Some(tx) = registry.get_codex_action_tx(&session_id) {
                let _ = tx
                    .send(CodexAction::SendMessage {
                        content: prompt,
                        model: resolved.model,
                        effort: resolved.effort,
                        skills: mission_skills,
                        images: vec![],
                        mentions: vec![],
                    })
                    .await;
            }
        }
        Provider::Claude => {
            // Claude: read skill content and prepend to the prompt
            let claude_prompt = match read_skill_content_for_claude(&resolved.skills) {
                Some(skill_content) => format!("{skill_content}\n\n{prompt}"),
                None => prompt,
            };
            if let Some(tx) = registry.get_claude_action_tx(&session_id) {
                let _ = tx
                    .send(ClaudeAction::SendMessage {
                        content: claude_prompt,
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
