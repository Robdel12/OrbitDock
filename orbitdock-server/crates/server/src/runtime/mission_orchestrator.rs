//! Mission Control orchestrator — async poll loop that drives the mission pipeline.
//!
//! Spawned as a tokio task at server startup. Each tick:
//! 1. Load enabled missions from DB
//! 2. For each mission: parse MISSION.md -> validate -> fetch candidates -> gate -> dispatch
//! 3. Broadcast MissionDelta on state changes

use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use orbitdock_protocol::{MissionIssueItem, MissionSummary, OrchestrationState, Provider};
use tracing::{debug, error, info, warn};

use crate::domain::mission_control::config::{parse_mission_file, MissionConfig};
use crate::domain::mission_control::eligibility::{is_eligible, sort_candidates};
use crate::domain::mission_control::tracker::Tracker;
use crate::infrastructure::persistence::mission_control::{
  load_manually_queued_issues, load_mission_by_id, load_mission_issues, load_missions,
  load_retry_ready_issues, MissionIssueRow, MissionRow,
};
use crate::infrastructure::persistence::PersistCommand;
use crate::runtime::session_registry::SessionRegistry;

use super::mission_dispatch::{dispatch_issue, DispatchContext};
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

  // Fast wake-up interval — per-mission gating happens inside process_mission
  let mut interval = tokio::time::interval(std::time::Duration::from_secs(15));

  // Track when each issue was last nudged to avoid spamming idle agents
  let mut nudge_tracker: HashMap<String, (std::time::Instant, u32)> = HashMap::new();

  // Track when each mission was last polled for per-mission interval gating
  let mut last_poll_at: HashMap<String, std::time::Instant> = HashMap::new();

  // Manual trigger channel — HTTP endpoint sends mission IDs to force immediate poll
  let mut trigger_rx = registry.take_mission_trigger_rx();

  loop {
    // Wait for either the interval tick or a manual trigger
    let triggered_mission = if let Some(ref mut rx) = trigger_rx {
      tokio::select! {
          _ = interval.tick() => None,
          msg = rx.recv() => msg,
      }
    } else {
      interval.tick().await;
      None
    };

    // Clear the poll gate for a manually triggered mission so it runs immediately
    if let Some(ref mission_id) = triggered_mission {
      last_poll_at.remove(mission_id);
    }

    if let Err(err) =
      orchestrator_tick(&registry, &tracker, &mut nudge_tracker, &mut last_poll_at).await
    {
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
  nudge_tracker: &mut HashMap<String, (std::time::Instant, u32)>,
  last_poll_at: &mut HashMap<String, std::time::Instant>,
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

    if let Err(err) =
      process_mission(registry, tracker, &mission, nudge_tracker, last_poll_at).await
    {
      warn!(
          component = "mission_control",
          event = "orchestrator.mission_error",
          mission_id = %mission.id,
          error = %err,
          "Failed to process mission"
      );
      // Broadcast updated state — don't persist tracker/runtime errors as
      // parse_error (that column is for MISSION.md parse failures only).
      broadcast_mission_delta_by_id(registry, &mission.id).await;
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
  nudge_tracker: &mut HashMap<String, (std::time::Instant, u32)>,
  last_poll_at: &mut HashMap<String, std::time::Instant>,
) -> anyhow::Result<()> {
  // Load and parse mission file (MISSION.md or custom path)
  let mission_file_path = mission.resolved_mission_path();
  let mission_content = match tokio::fs::read_to_string(&mission_file_path).await {
    Ok(content) => content,
    Err(err) => {
      debug!(
          component = "mission_control",
          mission_id = %mission.id,
          error = %err,
          "MISSION.md not found or unreadable"
      );
      // Record the missing file so the client knows why nothing is happening
      let _ = registry
        .persist()
        .send(PersistCommand::MissionUpdate {
          id: mission.id.clone(),
          name: None,
          enabled: None,
          paused: None,
          tracker_kind: None,
          config_json: None,
          prompt_template: None,
          parse_error: Some(Some("MISSION.md not found in repository".to_string())),
          mission_file_path: None,
        })
        .await;
      return Ok(());
    }
  };

  let workflow = match parse_mission_file(&mission_content) {
    Ok(w) => w,
    Err(err) => {
      let _ = registry
        .persist()
        .send(PersistCommand::MissionUpdate {
          id: mission.id.clone(),
          name: None,
          enabled: None,
          paused: None,
          tracker_kind: None,
          config_json: None,
          prompt_template: None,
          parse_error: Some(Some(err.to_string())),
          mission_file_path: None,
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
      name: None,
      enabled: None,
      paused: None,
      tracker_kind: None,
      config_json: Some(serde_json::to_string(&workflow.config).unwrap_or_default()),
      prompt_template: Some(workflow.prompt_template.clone()),
      parse_error: Some(None),
      mission_file_path: None,
    })
    .await;

  // Per-mission interval gating — skip if not enough time has elapsed
  let poll_interval_secs = workflow.config.trigger.interval;
  if let Some(last) = last_poll_at.get(&mission.id) {
    if last.elapsed() < std::time::Duration::from_secs(poll_interval_secs) {
      return Ok(());
    }
  }

  // Broadcast heartbeat now that this mission is due for processing
  let tick_now = chrono::Utc::now();
  let next_tick = tick_now + chrono::Duration::seconds(workflow.config.trigger.interval as i64);
  let heartbeat = orbitdock_protocol::ServerMessage::MissionHeartbeat {
    mission_id: mission.id.clone(),
    tick_started_at: tick_now.to_rfc3339(),
    next_tick_at: next_tick.to_rfc3339(),
  };
  let _ = registry.list_tx().send(heartbeat);

  // Load existing mission issues from DB (before candidate fetch so reconciliation runs first)
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

  // Reconcile existing issues (session completion, stall detection, tracker state check)
  reconcile_mission(
    registry,
    tracker,
    mission,
    &existing_issues,
    &workflow.config,
    nudge_tracker,
  )
  .await;

  // Skip candidate fetch + dispatch for manual-only missions
  if workflow.config.trigger.kind == "manual_only" {
    broadcast_mission_delta_by_id(registry, &mission.id).await;
    return Ok(());
  }

  // Fetch candidates from tracker
  let tracker_config = workflow.config.to_tracker_config();
  let mut candidates = tracker.fetch_candidates(&tracker_config).await?;

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
    let ctx = DispatchContext {
      repo_root: mission.repo_root.clone(),
      prompt_template: workflow.prompt_template.clone(),
      base_branch: workflow.config.orchestration.base_branch.clone(),
      agent_config: workflow.config.agent.clone(),
      workspace_config: workflow.config.workspace.clone(),
      worktree_root_dir: workflow.config.orchestration.worktree_root_dir.clone(),
      state_on_dispatch: workflow.config.orchestration.state_on_dispatch.clone(),
      tracker: tracker.clone(),
    };

    tokio::spawn(async move {
      let result = dispatch_issue(
        &registry,
        &mission_id,
        &candidate,
        &provider_str,
        &ctx,
        1, // first attempt for new candidates
      )
      .await;

      if let Err(ref err) = result {
        error!(
            component = "mission_control",
            event = "dispatch.failed",
            mission_id = %mission_id,
            issue_id = %candidate.id,
            error = %err,
            "Failed to dispatch issue"
        );
      }

      // Broadcast updated state immediately so the UI reflects the change
      broadcast_mission_delta_by_id(&registry, &mission_id).await;
    });
  }

  // Dispatch manually-queued issues (admin transitions) not in tracker candidates
  let candidate_ids: Vec<String> = candidates.iter().map(|c| c.id.clone()).collect();
  let manually_queued: Vec<MissionIssueRow> = {
    let path = db_path.clone();
    let mid = mission.id.clone();
    let exclude = candidate_ids;
    tokio::task::spawn_blocking(move || {
      let conn = rusqlite::Connection::open(&path)?;
      load_manually_queued_issues(&conn, &mid, &exclude)
    })
    .await??
  };

  for queued_row in manually_queued {
    if current_running >= workflow.config.provider.max_concurrent {
      break;
    }

    let queued_issue = crate::domain::mission_control::tracker::TrackerIssue {
      id: queued_row.issue_id.clone(),
      identifier: queued_row.issue_identifier.clone(),
      title: queued_row.issue_title.clone().unwrap_or_default(),
      description: None,
      priority: None,
      state: queued_row.issue_state.clone().unwrap_or_default(),
      url: queued_row.url.clone(),
      labels: vec![],
      blocked_by: vec![],
      created_at: Some(queued_row.created_at.clone()),
    };

    let chosen_provider = choose_provider(&workflow.config, &provider_counts, dispatch_index);
    current_running += 1;
    provider_counts.increment(&chosen_provider);
    dispatch_index += 1;

    let attempt = queued_row.attempt;
    let registry = registry.clone();
    let mission_id = mission.id.clone();
    let provider_str = chosen_provider;
    let ctx = DispatchContext {
      repo_root: mission.repo_root.clone(),
      prompt_template: workflow.prompt_template.clone(),
      base_branch: workflow.config.orchestration.base_branch.clone(),
      agent_config: workflow.config.agent.clone(),
      workspace_config: workflow.config.workspace.clone(),
      worktree_root_dir: workflow.config.orchestration.worktree_root_dir.clone(),
      state_on_dispatch: workflow.config.orchestration.state_on_dispatch.clone(),
      tracker: tracker.clone(),
    };

    tokio::spawn(async move {
      let result = dispatch_issue(
        &registry,
        &mission_id,
        &queued_issue,
        &provider_str,
        &ctx,
        attempt,
      )
      .await;

      if let Err(ref err) = result {
        error!(
            component = "mission_control",
            event = "dispatch.manual_queue_failed",
            mission_id = %mission_id,
            issue_id = %queued_issue.id,
            error = %err,
            "Failed to dispatch manually-queued issue"
        );
      }

      broadcast_mission_delta_by_id(&registry, &mission_id).await;
    });
  }

  // Dispatch retry-ready issues
  let mission_id_retry = mission.id.clone();
  let now_str = chrono::Utc::now().to_rfc3339();
  let max_retries = workflow.config.orchestration.max_retries;
  let retry_issues: Vec<MissionIssueRow> = {
    let path = db_path;
    let mid = mission_id_retry;
    let now = now_str;
    tokio::task::spawn_blocking(move || {
      let conn = rusqlite::Connection::open(&path)?;
      load_retry_ready_issues(&conn, &mid, &now, max_retries)
    })
    .await??
  };

  for retry_row in retry_issues {
    if current_running >= workflow.config.provider.max_concurrent {
      break;
    }

    // Build a TrackerIssue from the row to reuse dispatch
    let retry_issue = crate::domain::mission_control::tracker::TrackerIssue {
      id: retry_row.issue_id.clone(),
      identifier: retry_row.issue_identifier.clone(),
      title: retry_row.issue_title.clone().unwrap_or_default(),
      description: None,
      priority: None,
      state: retry_row.issue_state.clone().unwrap_or_default(),
      url: retry_row.url.clone(),
      labels: vec![],
      blocked_by: vec![],
      created_at: Some(retry_row.created_at.clone()),
    };

    let chosen_provider = choose_provider(&workflow.config, &provider_counts, dispatch_index);
    current_running += 1;
    provider_counts.increment(&chosen_provider);
    dispatch_index += 1;

    let attempt = retry_row.attempt;
    let registry = registry.clone();
    let mission_id = mission.id.clone();
    let provider_str = chosen_provider;
    let ctx = DispatchContext {
      repo_root: mission.repo_root.clone(),
      prompt_template: workflow.prompt_template.clone(),
      base_branch: workflow.config.orchestration.base_branch.clone(),
      agent_config: workflow.config.agent.clone(),
      workspace_config: workflow.config.workspace.clone(),
      worktree_root_dir: workflow.config.orchestration.worktree_root_dir.clone(),
      state_on_dispatch: workflow.config.orchestration.state_on_dispatch.clone(),
      tracker: tracker.clone(),
    };

    tokio::spawn(async move {
      let result = dispatch_issue(
        &registry,
        &mission_id,
        &retry_issue,
        &provider_str,
        &ctx,
        attempt,
      )
      .await;

      if let Err(ref err) = result {
        error!(
            component = "mission_control",
            event = "dispatch.retry_failed",
            mission_id = %mission_id,
            issue_id = %retry_issue.id,
            attempt = attempt,
            error = %err,
            "Failed to dispatch retry issue"
        );
      }

      broadcast_mission_delta_by_id(&registry, &mission_id).await;
    });
  }

  // Record that we processed this mission
  last_poll_at.insert(mission.id.clone(), std::time::Instant::now());

  // Broadcast MissionDelta (reload from DB to include any PersistCommand updates)
  broadcast_mission_delta_by_id(registry, &mission.id).await;

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
        "provisioning" => {
          active_count += 1;
          OrchestrationState::Provisioning
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
        "blocked" => {
          failed_count += 1;
          OrchestrationState::Blocked
        }
        _ => {
          queued_count += 1;
          OrchestrationState::Queued
        }
      };

      // Enrich with live session data if available
      let (work_status, last_message, last_activity) = row
        .session_id
        .as_deref()
        .and_then(|sid| registry.get_session(sid))
        .map(|handle| {
          let snap = handle.snapshot();
          let ws = snap.work_status;
          let msg = snap.last_message.clone();
          let activity = snap.last_progress_at.clone();
          (Some(ws), msg, activity)
        })
        .unwrap_or((None, None, None));

      MissionIssueItem {
        issue_id: row.issue_id.clone(),
        identifier: row.issue_identifier.clone(),
        title: row.issue_title.clone().unwrap_or_default(),
        tracker_state: row.issue_state.clone().unwrap_or_default(),
        orchestration_state: state,
        session_id: row.session_id.clone(),
        provider: row
          .provider
          .as_deref()
          .unwrap_or("claude")
          .parse::<Provider>()
          .unwrap_or_else(|_| {
            warn!(
                component = "mission_control",
                event = "provider.invalid_issue",
                issue_id = %row.issue_id,
                raw_value = ?row.provider,
                "Invalid provider for issue, falling back to Claude"
            );
            Provider::Claude
          }),
        attempt: row.attempt,
        error: row.last_error.clone(),
        url: row.url.clone(),
        last_activity,
        started_at: row.started_at.clone(),
        completed_at: row.completed_at.clone(),
        allowed_transitions: state.allowed_transitions(),
        work_status,
        last_message,
        pr_url: row.pr_url.clone(),
      }
    })
    .collect();

  let primary_provider: Provider = mission.provider.parse().unwrap_or_else(|_| {
    warn!(
        component = "mission_control",
        event = "provider.invalid_mission",
        mission_id = %mission.id,
        raw_value = %mission.provider,
        "Invalid primary provider for mission, falling back to Claude"
    );
    Provider::Claude
  });

  let orchestrator_running = registry.is_orchestrator_running();
  let orchestrator_status =
    crate::domain::mission_control::compute_orchestrator_status(mission, orchestrator_running);

  // Read strategy from config_json if available
  let (provider_strategy, secondary_provider) = if let Some(ref json) = mission.config_json {
    if let Ok(config) =
      serde_json::from_str::<crate::domain::mission_control::config::MissionConfig>(json)
    {
      let secondary = config.provider.secondary.as_ref().and_then(|s| {
        s.parse::<Provider>().ok().or_else(|| {
          warn!(
              component = "mission_control",
              event = "provider.invalid_secondary",
              mission_id = %mission.id,
              raw_value = %s,
              "Invalid secondary provider for mission, dropping to None"
          );
          None
        })
      });
      (config.provider.strategy, secondary)
    } else {
      ("single".to_string(), None)
    }
  } else {
    ("single".to_string(), None)
  };

  let summary = MissionSummary {
    id: mission.id.clone(),
    name: mission.name.clone(),
    repo_root: mission.repo_root.clone(),
    enabled: mission.enabled,
    paused: mission.paused,
    tracker_kind: mission.tracker_kind.clone(),
    provider: primary_provider,
    provider_strategy,
    primary_provider,
    secondary_provider,
    active_count,
    queued_count,
    completed_count,
    failed_count,
    parse_error: mission.parse_error.clone(),
    orchestrator_status,
    last_polled_at: Some(chrono::Utc::now().to_rfc3339()),
    poll_interval: {
      // Try to extract interval from config_json
      mission.config_json.as_ref().and_then(|json| {
        serde_json::from_str::<crate::domain::mission_control::config::MissionConfig>(json)
          .ok()
          .map(|c| c.trigger.interval)
      })
    },
    mission_file_path: mission.mission_file_path.clone(),
    tracker_key_source: crate::support::api_keys::tracker_key_source_for_mission(
      &mission.id,
      &mission.tracker_kind,
    )
    .map(|s| s.to_string()),
  };

  let msg = orbitdock_protocol::ServerMessage::MissionDelta {
    mission_id,
    issues,
    summary,
  };

  let _ = registry.list_tx().send(msg);
  registry.publish_missions_snapshot();
}

/// Broadcast a MissionDelta by loading the mission from DB.
/// Used by spawned dispatch tasks that don't have the MissionRow in scope.
pub async fn broadcast_mission_delta_by_id(registry: &Arc<SessionRegistry>, mission_id: &str) {
  let db_path = registry.db_path().clone();
  let mid = mission_id.to_string();
  let mission = {
    let path = db_path;
    let id = mid;
    tokio::task::spawn_blocking(move || {
      let conn = rusqlite::Connection::open(&path)?;
      load_mission_by_id(&conn, &id)
    })
    .await
    .unwrap_or_else(|e| Err(anyhow::anyhow!("join error: {e}")))
  };

  if let Ok(Some(row)) = mission {
    broadcast_mission_delta(registry, &row).await;
  }
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
