//! Mission Control orchestrator — async poll loop that drives the mission pipeline.
//!
//! Spawned as a tokio task at server startup. Each tick:
//! 1. Load enabled missions from DB
//! 2. For each mission: parse WORKFLOW.md -> validate -> fetch candidates -> gate -> dispatch
//! 3. Broadcast MissionDelta on state changes

use std::collections::HashSet;
use std::path::Path;
use std::sync::Arc;

use orbitdock_protocol::{MissionIssueItem, MissionSummary, OrchestrationState, Provider};
use tracing::{debug, error, info, warn};

use crate::domain::mission_control::config::{parse_workflow, MissionConfig};
use crate::domain::mission_control::eligibility::{is_eligible, sort_candidates};
use crate::domain::mission_control::tracker::Tracker;
use crate::infrastructure::persistence::mission_control::{
    load_mission_issues, load_missions, MissionIssueRow, MissionRow,
};
use crate::infrastructure::persistence::PersistCommand;
use crate::runtime::session_registry::SessionRegistry;

use super::mission_dispatch::dispatch_issue;
use super::mission_reconciliation::reconcile_mission;

/// Start the mission orchestrator loop.
///
/// Runs until the server shuts down. Safe to call even if no missions
/// are configured — the loop idles at the poll interval.
pub async fn start_mission_orchestrator(registry: Arc<SessionRegistry>, tracker: Arc<dyn Tracker>) {
    info!(
        component = "mission_control",
        event = "orchestrator.started",
        "Mission orchestrator started"
    );

    // Initial poll interval — overridden per-mission once we parse WORKFLOW.md
    let mut interval = tokio::time::interval(std::time::Duration::from_secs(60));

    loop {
        interval.tick().await;

        if let Err(err) = orchestrator_tick(&registry, &tracker).await {
            error!(
                component = "mission_control",
                event = "orchestrator.tick_error",
                error = %err,
                "Orchestrator tick failed"
            );
        }
    }
}

async fn orchestrator_tick(
    registry: &Arc<SessionRegistry>,
    tracker: &Arc<dyn Tracker>,
) -> anyhow::Result<()> {
    let db_path = registry.db_path().clone();
    let missions = {
        let path = db_path.clone();
        tokio::task::spawn_blocking(move || {
            let conn = rusqlite::Connection::open(&path)?;
            load_missions(&conn)
        })
        .await??
    };

    for mission in missions {
        if !mission.enabled || mission.paused {
            continue;
        }

        if let Err(err) = process_mission(registry, tracker, &mission).await {
            warn!(
                component = "mission_control",
                event = "orchestrator.mission_error",
                mission_id = %mission.id,
                error = %err,
                "Failed to process mission"
            );
        }
    }

    Ok(())
}

/// Choose which provider to use for a dispatch based on the config strategy.
fn choose_provider(
    config: &MissionConfig,
    running_by_provider: &ProviderCounts,
    dispatch_index: u32,
) -> String {
    let strategy = config.provider.strategy.as_str();
    let primary = &config.provider.primary;
    let secondary = config.provider.secondary.as_deref();

    match strategy {
        "priority" => {
            if let (Some(secondary_name), Some(max_primary)) =
                (secondary, config.provider.max_concurrent_primary)
            {
                if running_by_provider.count(primary) >= max_primary {
                    return secondary_name.to_string();
                }
            }
            primary.clone()
        }
        "round_robin" => {
            if let Some(secondary_name) = secondary {
                if dispatch_index.is_multiple_of(2) {
                    primary.clone()
                } else {
                    secondary_name.to_string()
                }
            } else {
                primary.clone()
            }
        }
        // "single" or anything else
        _ => primary.clone(),
    }
}

/// Tracks running issue counts per provider.
struct ProviderCounts {
    counts: std::collections::HashMap<String, u32>,
}

impl ProviderCounts {
    fn new() -> Self {
        Self {
            counts: std::collections::HashMap::new(),
        }
    }

    fn increment(&mut self, provider: &str) {
        *self.counts.entry(provider.to_string()).or_insert(0) += 1;
    }

    fn count(&self, provider: &str) -> u32 {
        self.counts.get(provider).copied().unwrap_or(0)
    }
}

async fn process_mission(
    registry: &Arc<SessionRegistry>,
    tracker: &Arc<dyn Tracker>,
    mission: &MissionRow,
) -> anyhow::Result<()> {
    // Load and parse WORKFLOW.md
    let workflow_path = Path::new(&mission.repo_root).join("WORKFLOW.md");
    let workflow_content = match tokio::fs::read_to_string(&workflow_path).await {
        Ok(content) => content,
        Err(err) => {
            debug!(
                component = "mission_control",
                mission_id = %mission.id,
                error = %err,
                "WORKFLOW.md not found or unreadable"
            );
            // Record the missing file so the client knows why nothing is happening
            let _ = registry
                .persist()
                .send(PersistCommand::MissionUpdate {
                    id: mission.id.clone(),
                    enabled: None,
                    paused: None,
                    config_json: None,
                    prompt_template: None,
                    parse_error: Some(Some("WORKFLOW.md not found in repository".to_string())),
                })
                .await;
            return Ok(());
        }
    };

    let workflow = match parse_workflow(&workflow_content) {
        Ok(w) => w,
        Err(err) => {
            let _ = registry
                .persist()
                .send(PersistCommand::MissionUpdate {
                    id: mission.id.clone(),
                    enabled: None,
                    paused: None,
                    config_json: None,
                    prompt_template: None,
                    parse_error: Some(Some(err.to_string())),
                })
                .await;
            return Ok(());
        }
    };

    // Clear parse error on success
    let _ = registry
        .persist()
        .send(PersistCommand::MissionUpdate {
            id: mission.id.clone(),
            enabled: None,
            paused: None,
            config_json: Some(serde_json::to_string(&workflow.config).unwrap_or_default()),
            prompt_template: Some(workflow.prompt_template.clone()),
            parse_error: Some(None),
        })
        .await;

    // Fetch candidates from tracker
    let tracker_config = workflow.config.to_tracker_config();
    let mut candidates = tracker.fetch_candidates(&tracker_config).await?;

    // Load existing mission issues from DB
    let db_path = registry.db_path().clone();
    let mission_id = mission.id.clone();
    let existing_issues: Vec<MissionIssueRow> = {
        let path = db_path.clone();
        tokio::task::spawn_blocking(move || {
            let conn = rusqlite::Connection::open(&path)?;
            load_mission_issues(&conn, &mission_id)
        })
        .await??
    };

    // Build running/claimed sets + per-provider counts
    let mut running_ids = HashSet::new();
    let mut claimed_ids = HashSet::new();
    let mut current_running = 0u32;
    let mut provider_counts = ProviderCounts::new();

    for issue_row in &existing_issues {
        match issue_row.orchestration_state.as_str() {
            "running" => {
                running_ids.insert(issue_row.issue_id.clone());
                current_running += 1;
                if let Some(p) = &issue_row.provider {
                    provider_counts.increment(p);
                }
            }
            "claimed" => {
                claimed_ids.insert(issue_row.issue_id.clone());
                current_running += 1;
                if let Some(p) = &issue_row.provider {
                    provider_counts.increment(p);
                }
            }
            _ => {}
        }
    }

    // Reconcile existing issues (stall detection, tracker state check)
    reconcile_mission(
        registry,
        tracker,
        mission,
        &existing_issues,
        &workflow.config,
    )
    .await;

    // Upsert all tracker candidates into mission_issues
    for candidate in &candidates {
        let issue_row_id = orbitdock_protocol::new_id();
        let _ = registry
            .persist()
            .send(PersistCommand::MissionIssueUpsert {
                id: issue_row_id,
                mission_id: mission.id.clone(),
                issue_id: candidate.id.clone(),
                issue_identifier: candidate.identifier.clone(),
                issue_title: Some(candidate.title.clone()),
                issue_state: Some(candidate.state.clone()),
                orchestration_state: "queued".to_string(),
                provider: Some(workflow.config.provider.primary.clone()),
                url: candidate.url.clone(),
            })
            .await;
    }

    // Sort and dispatch eligible candidates
    sort_candidates(&mut candidates);

    let mut dispatch_index = 0u32;
    for candidate in &candidates {
        if !is_eligible(
            candidate,
            &running_ids,
            &claimed_ids,
            workflow.config.provider.max_concurrent,
            current_running,
        ) {
            continue;
        }

        // Choose provider based on strategy
        let chosen_provider = choose_provider(&workflow.config, &provider_counts, dispatch_index);

        // Claim
        claimed_ids.insert(candidate.id.clone());
        current_running += 1;
        provider_counts.increment(&chosen_provider);
        dispatch_index += 1;

        let registry = registry.clone();
        let candidate = candidate.clone();
        let mission_id = mission.id.clone();
        let provider_str = chosen_provider;
        let repo_root = mission.repo_root.clone();
        let prompt_template = workflow.prompt_template.clone();
        let base_branch = workflow.config.orchestration.base_branch.clone();

        tokio::spawn(async move {
            if let Err(err) = dispatch_issue(
                &registry,
                &mission_id,
                &candidate,
                &provider_str,
                &repo_root,
                &prompt_template,
                &base_branch,
            )
            .await
            {
                error!(
                    component = "mission_control",
                    event = "dispatch.failed",
                    mission_id = %mission_id,
                    issue_id = %candidate.id,
                    error = %err,
                    "Failed to dispatch issue"
                );
            }
        });
    }

    // Broadcast MissionDelta
    broadcast_mission_delta(registry, mission).await;

    Ok(())
}

/// Build and broadcast a MissionDelta message for a mission.
pub async fn broadcast_mission_delta(registry: &Arc<SessionRegistry>, mission: &MissionRow) {
    let db_path = registry.db_path().clone();
    let mission_id = mission.id.clone();

    let issues_result: anyhow::Result<Vec<MissionIssueRow>> = {
        let path = db_path;
        let mid = mission_id.clone();
        tokio::task::spawn_blocking(move || {
            let conn = rusqlite::Connection::open(&path)?;
            load_mission_issues(&conn, &mid)
        })
        .await
        .unwrap_or_else(|e| Err(anyhow::anyhow!("join error: {e}")))
    };

    let issue_rows = match issues_result {
        Ok(rows) => rows,
        Err(_) => return,
    };

    let mut active_count = 0u32;
    let mut queued_count = 0u32;
    let mut completed_count = 0u32;
    let mut failed_count = 0u32;

    let issues: Vec<MissionIssueItem> = issue_rows
        .iter()
        .map(|row| {
            let state = match row.orchestration_state.as_str() {
                "queued" => {
                    queued_count += 1;
                    OrchestrationState::Queued
                }
                "claimed" => {
                    active_count += 1;
                    OrchestrationState::Claimed
                }
                "running" => {
                    active_count += 1;
                    OrchestrationState::Running
                }
                "retry_queued" => {
                    queued_count += 1;
                    OrchestrationState::RetryQueued
                }
                "completed" => {
                    completed_count += 1;
                    OrchestrationState::Completed
                }
                "failed" => {
                    failed_count += 1;
                    OrchestrationState::Failed
                }
                _ => {
                    queued_count += 1;
                    OrchestrationState::Queued
                }
            };

            MissionIssueItem {
                issue_id: row.issue_id.clone(),
                identifier: row.issue_identifier.clone(),
                title: row.issue_title.clone().unwrap_or_default(),
                tracker_state: row.issue_state.clone().unwrap_or_default(),
                orchestration_state: state,
                session_id: row.session_id.clone(),
                provider: match row.provider.as_deref() {
                    Some("codex") => Provider::Codex,
                    _ => Provider::Claude,
                },
                attempt: row.attempt,
                error: row.last_error.clone(),
                url: None,
                last_activity: None,
            }
        })
        .collect();

    let primary_provider = match mission.provider.as_str() {
        "codex" => Provider::Codex,
        _ => Provider::Claude,
    };

    let orchestrator_status = if !mission.enabled {
        Some("disabled".to_string())
    } else if mission.paused {
        Some("paused".to_string())
    } else if mission.parse_error.is_some() {
        Some("config_error".to_string())
    } else if crate::support::api_keys::resolve_linear_api_key().is_none() {
        Some("no_api_key".to_string())
    } else {
        Some("polling".to_string())
    };

    let summary = MissionSummary {
        id: mission.id.clone(),
        repo_root: mission.repo_root.clone(),
        enabled: mission.enabled,
        paused: mission.paused,
        tracker_kind: mission.tracker_kind.clone(),
        provider: primary_provider,
        provider_strategy: "single".to_string(),
        primary_provider,
        secondary_provider: None,
        active_count,
        queued_count,
        completed_count,
        failed_count,
        parse_error: mission.parse_error.clone(),
        orchestrator_status,
    };

    let msg = orbitdock_protocol::ServerMessage::MissionDelta {
        mission_id,
        issues,
        summary,
    };

    let _ = registry.list_tx().send(msg);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::mission_control::config::{MissionConfig, ProviderConfig};

    fn config_with(
        strategy: &str,
        primary: &str,
        secondary: Option<&str>,
        max_primary: Option<u32>,
    ) -> MissionConfig {
        MissionConfig {
            provider: ProviderConfig {
                strategy: strategy.to_string(),
                primary: primary.to_string(),
                secondary: secondary.map(|s| s.to_string()),
                max_concurrent: 5,
                max_concurrent_primary: max_primary,
            },
            ..Default::default()
        }
    }

    // -- single strategy --

    #[test]
    fn single_always_returns_primary() {
        let config = config_with("single", "claude", None, None);
        let counts = ProviderCounts::new();
        assert_eq!(choose_provider(&config, &counts, 0), "claude");
        assert_eq!(choose_provider(&config, &counts, 5), "claude");
    }

    #[test]
    fn single_ignores_secondary_even_if_set() {
        let config = config_with("single", "claude", Some("codex"), None);
        let counts = ProviderCounts::new();
        assert_eq!(choose_provider(&config, &counts, 0), "claude");
    }

    // -- priority strategy --

    #[test]
    fn priority_uses_primary_when_under_limit() {
        let config = config_with("priority", "claude", Some("codex"), Some(3));
        let mut counts = ProviderCounts::new();
        counts.increment("claude"); // 1 running
        assert_eq!(choose_provider(&config, &counts, 0), "claude");
    }

    #[test]
    fn priority_overflows_to_secondary_at_limit() {
        let config = config_with("priority", "claude", Some("codex"), Some(2));
        let mut counts = ProviderCounts::new();
        counts.increment("claude");
        counts.increment("claude"); // 2 running = at limit
        assert_eq!(choose_provider(&config, &counts, 0), "codex");
    }

    #[test]
    fn priority_falls_back_to_primary_without_secondary() {
        let config = config_with("priority", "claude", None, Some(2));
        let mut counts = ProviderCounts::new();
        counts.increment("claude");
        counts.increment("claude");
        // No secondary configured — should still return primary
        assert_eq!(choose_provider(&config, &counts, 0), "claude");
    }

    #[test]
    fn priority_falls_back_to_primary_without_max_primary() {
        let config = config_with("priority", "claude", Some("codex"), None);
        let mut counts = ProviderCounts::new();
        counts.increment("claude");
        counts.increment("claude");
        counts.increment("claude");
        // No max_concurrent_primary set — never overflows
        assert_eq!(choose_provider(&config, &counts, 0), "claude");
    }

    // -- round_robin strategy --

    #[test]
    fn round_robin_alternates() {
        let config = config_with("round_robin", "claude", Some("codex"), None);
        let counts = ProviderCounts::new();
        assert_eq!(choose_provider(&config, &counts, 0), "claude");
        assert_eq!(choose_provider(&config, &counts, 1), "codex");
        assert_eq!(choose_provider(&config, &counts, 2), "claude");
        assert_eq!(choose_provider(&config, &counts, 3), "codex");
    }

    #[test]
    fn round_robin_uses_primary_without_secondary() {
        let config = config_with("round_robin", "claude", None, None);
        let counts = ProviderCounts::new();
        assert_eq!(choose_provider(&config, &counts, 0), "claude");
        assert_eq!(choose_provider(&config, &counts, 1), "claude");
    }

    // -- unknown strategy --

    #[test]
    fn unknown_strategy_defaults_to_primary() {
        let config = config_with("banana", "codex", Some("claude"), None);
        let counts = ProviderCounts::new();
        assert_eq!(choose_provider(&config, &counts, 0), "codex");
    }
}
