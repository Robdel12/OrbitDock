use std::path::{Path, PathBuf};
use std::sync::Arc;

use orbitdock_protocol::{
  ClaudeIntegrationMode, CodexIntegrationMode, DashboardConversationItem, DashboardCounts,
  DashboardDiffPreview, DashboardSnapshot, Provider, SessionControlMode, SessionLifecycleState,
  SessionListItem, SessionListStatus, SessionState, SessionStatus, SessionSummary, TokenUsage,
  WorkStatus,
};
use rusqlite::Connection;
use tracing::warn;

use crate::domain::sessions::conversation::{ConversationBootstrap, ConversationPage};
use crate::infrastructure::persistence::{
  load_message_page_for_session, load_session_by_id, load_session_metadata_by_id,
  load_subagents_for_session, snapshot_kind_from_str,
};
use crate::runtime::conversation_policy::{
  conversation_page_from_rows, prepend_conversation_page, requires_coherent_history_page,
  COHERENT_HISTORY_MAX_ROWS,
};
use crate::runtime::restored_sessions::{
  hydrate_restored_rows_if_missing, restored_session_to_state,
};
use crate::runtime::session_registry::SessionRegistry;

#[derive(Debug)]
pub(crate) enum SessionLoadError {
  NotFound,
  Db(String),
  Runtime(String),
}

#[derive(Debug)]
struct PersistedDashboardProjection {
  id: String,
  provider: Provider,
  status: SessionStatus,
  work_status: WorkStatus,
  control_mode: SessionControlMode,
  lifecycle_state: SessionLifecycleState,
  project_path: String,
  project_name: Option<String>,
  repository_root: Option<String>,
  git_branch: Option<String>,
  is_worktree: bool,
  worktree_id: Option<String>,
  model: Option<String>,
  codex_integration_mode: Option<CodexIntegrationMode>,
  claude_integration_mode: Option<ClaudeIntegrationMode>,
  custom_name: Option<String>,
  summary: Option<String>,
  first_prompt: Option<String>,
  last_message: Option<String>,
  started_at: Option<String>,
  last_activity_at: Option<String>,
  unread_count: u64,
  current_diff: Option<String>,
  pending_tool_name: Option<String>,
  pending_tool_input: Option<String>,
  pending_question: Option<String>,
  tool_count: u64,
  active_worker_count: u32,
  issue_identifier: Option<String>,
  effort: Option<String>,
  approval_policy: Option<String>,
  sandbox_mode: Option<String>,
  permission_mode: Option<String>,
  collaboration_mode: Option<String>,
  multi_agent: Option<bool>,
  personality: Option<String>,
  service_tier: Option<String>,
  developer_instructions: Option<String>,
  token_usage: TokenUsage,
  token_usage_snapshot_kind: orbitdock_protocol::TokenUsageSnapshotKind,
  pending_approval_id: Option<String>,
  mission_id: Option<String>,
  allow_bypass_permissions: bool,
  forked_from_session_id: Option<String>,
  approval_version: u64,
}

fn parse_provider(value: &str) -> Provider {
  if value.eq_ignore_ascii_case("codex") {
    Provider::Codex
  } else {
    Provider::Claude
  }
}

fn parse_status(value: &str) -> SessionStatus {
  if value.eq_ignore_ascii_case("ended") {
    SessionStatus::Ended
  } else {
    SessionStatus::Active
  }
}

fn parse_work_status(status: SessionStatus, value: &str) -> WorkStatus {
  if status == SessionStatus::Ended || value.eq_ignore_ascii_case("ended") {
    return WorkStatus::Ended;
  }

  if value.eq_ignore_ascii_case("working") {
    WorkStatus::Working
  } else if value.eq_ignore_ascii_case("permission") {
    WorkStatus::Permission
  } else if value.eq_ignore_ascii_case("question") {
    WorkStatus::Question
  } else if value.eq_ignore_ascii_case("reply") {
    WorkStatus::Reply
  } else {
    WorkStatus::Waiting
  }
}

fn parse_control_mode(value: &str) -> SessionControlMode {
  if value.eq_ignore_ascii_case("direct") {
    SessionControlMode::Direct
  } else {
    SessionControlMode::Passive
  }
}

fn parse_lifecycle_state(value: &str) -> SessionLifecycleState {
  if value.eq_ignore_ascii_case("resumable") {
    SessionLifecycleState::Resumable
  } else if value.eq_ignore_ascii_case("ended") {
    SessionLifecycleState::Ended
  } else {
    SessionLifecycleState::Open
  }
}

fn normalize_integration_modes(
  provider: Provider,
  control_mode: SessionControlMode,
) -> (Option<CodexIntegrationMode>, Option<ClaudeIntegrationMode>) {
  match provider {
    Provider::Codex => (
      Some(match control_mode {
        SessionControlMode::Direct => CodexIntegrationMode::Direct,
        SessionControlMode::Passive => CodexIntegrationMode::Passive,
      }),
      None,
    ),
    Provider::Claude => (
      None,
      Some(match control_mode {
        SessionControlMode::Direct => ClaudeIntegrationMode::Direct,
        SessionControlMode::Passive => ClaudeIntegrationMode::Passive,
      }),
    ),
  }
}

fn has_turn_diff(diff: Option<&str>) -> bool {
  diff.is_some_and(|value| !value.trim().is_empty())
}

async fn load_persisted_dashboard_projections(
  db_path: PathBuf,
) -> Result<Vec<PersistedDashboardProjection>, SessionLoadError> {
  tokio::task::spawn_blocking(move || -> Result<Vec<PersistedDashboardProjection>, SessionLoadError> {
      if !db_path.exists() {
        return Ok(Vec::new());
      }

      let conn = Connection::open(&db_path).map_err(|err| SessionLoadError::Db(err.to_string()))?;
      conn
        .execute_batch(
          "PRAGMA journal_mode = WAL;
           PRAGMA busy_timeout = 5000;",
        )
        .map_err(|err| SessionLoadError::Db(err.to_string()))?;

      let mut stmt = conn
        .prepare(
          "SELECT s.id,
                  s.provider,
                  s.status,
                  s.work_status,
                  COALESCE(s.control_mode, CASE
                      WHEN s.provider = 'claude' AND s.claude_integration_mode = 'direct' THEN 'direct'
                      WHEN s.provider = 'codex' AND s.codex_integration_mode = 'direct' THEN 'direct'
                      ELSE 'passive'
                  END),
                  COALESCE(s.lifecycle_state, CASE WHEN s.status = 'ended' THEN 'ended' ELSE 'open' END),
                  s.project_path,
                  s.project_name,
                  s.repository_root,
                  s.git_branch,
                  COALESCE(s.is_worktree, 0),
                  s.worktree_id,
                  s.model,
                  s.codex_integration_mode,
                  s.claude_integration_mode,
                  s.custom_name,
                  s.summary,
                  s.first_prompt,
                  s.last_message,
                  s.started_at,
                  s.last_activity_at,
                  COALESCE(s.unread_count, 0),
                  s.current_diff,
                  s.pending_tool_name,
                  s.pending_tool_input,
                  s.pending_question,
                  COALESCE(s.tool_count, 0),
                  COALESCE((SELECT COUNT(*) FROM subagents sa WHERE sa.session_id = s.id AND sa.status = 'running'), 0),
                  s.issue_identifier,
                  s.effort,
                  s.approval_policy,
                  s.sandbox_mode,
                  s.permission_mode,
                  s.collaboration_mode,
                  s.multi_agent,
                  s.personality,
                  s.service_tier,
                  s.developer_instructions,
                  COALESCE(uss.snapshot_input_tokens, s.input_tokens, 0),
                  COALESCE(uss.snapshot_output_tokens, s.output_tokens, 0),
                  COALESCE(uss.snapshot_cached_tokens, s.cached_tokens, 0),
                  COALESCE(uss.snapshot_context_window, s.context_window, 0),
                  COALESCE(uss.snapshot_kind, 'unknown'),
                  s.pending_approval_id,
                  s.mission_id,
                  COALESCE(s.allow_bypass_permissions, 0),
                  s.forked_from_session_id,
                  COALESCE(s.approval_version, 0)
           FROM sessions s
           LEFT JOIN usage_session_state uss ON uss.session_id = s.id
           ORDER BY
             COALESCE(
               CAST(REPLACE(s.last_progress_at, 'Z', '') AS INTEGER),
               CAST(REPLACE(s.last_activity_at, 'Z', '') AS INTEGER),
               0
             ) DESC,
             COALESCE(CAST(REPLACE(s.last_activity_at, 'Z', '') AS INTEGER), 0) DESC",
        )
        .map_err(|err| SessionLoadError::Db(err.to_string()))?;

      let rows = stmt
        .query_map([], |row| {
          let provider = parse_provider(&row.get::<_, String>(1)?);
          let status = parse_status(&row.get::<_, String>(2)?);
          let work_status = parse_work_status(status, &row.get::<_, String>(3)?);
          let control_mode = parse_control_mode(&row.get::<_, String>(4)?);
          let lifecycle_state = parse_lifecycle_state(&row.get::<_, String>(5)?);
          let (codex_integration_mode, claude_integration_mode) =
            normalize_integration_modes(provider, control_mode);

          let multi_agent: Option<i64> = row.get(34)?;
          let input_tokens: i64 = row.get(38)?;
          let output_tokens: i64 = row.get(39)?;
          let cached_tokens: i64 = row.get(40)?;
          let context_window: i64 = row.get(41)?;
          let snapshot_kind: String = row.get(42)?;

          Ok(PersistedDashboardProjection {
            id: row.get(0)?,
            provider,
            status,
            work_status,
            control_mode,
            lifecycle_state,
            project_path: row.get(6)?,
            project_name: row.get(7)?,
            repository_root: row.get(8)?,
            git_branch: row.get(9)?,
            is_worktree: row.get::<_, i64>(10)? != 0,
            worktree_id: row.get(11)?,
            model: row.get(12)?,
            codex_integration_mode,
            claude_integration_mode,
            custom_name: row.get(15)?,
            summary: row.get(16)?,
            first_prompt: row.get(17)?,
            last_message: row.get(18)?,
            started_at: row.get(19)?,
            last_activity_at: row.get(20)?,
            unread_count: row.get::<_, i64>(21)?.max(0) as u64,
            current_diff: row.get(22)?,
            pending_tool_name: row.get(23)?,
            pending_tool_input: row.get(24)?,
            pending_question: row.get(25)?,
            tool_count: row.get::<_, i64>(26)?.max(0) as u64,
            active_worker_count: row.get::<_, i64>(27)?.max(0) as u32,
            issue_identifier: row.get(28)?,
            effort: row.get(29)?,
            approval_policy: row.get(30)?,
            sandbox_mode: row.get(31)?,
            permission_mode: row.get(32)?,
            collaboration_mode: row.get(33)?,
            multi_agent: multi_agent.map(|value| value != 0),
            personality: row.get(35)?,
            service_tier: row.get(36)?,
            developer_instructions: row.get(37)?,
            token_usage: TokenUsage {
              input_tokens: input_tokens.max(0) as u64,
              output_tokens: output_tokens.max(0) as u64,
              cached_tokens: cached_tokens.max(0) as u64,
              context_window: context_window.max(0) as u64,
            },
            token_usage_snapshot_kind: snapshot_kind_from_str(Some(snapshot_kind.as_str())),
            pending_approval_id: row.get(43)?,
            mission_id: row.get(44)?,
            allow_bypass_permissions: row.get::<_, i64>(45)? != 0,
            forked_from_session_id: row.get(46)?,
            approval_version: row.get::<_, i64>(47)?.max(0) as u64,
          })
        })
        .map_err(|err| SessionLoadError::Db(err.to_string()))?;

      Ok(rows.filter_map(Result::ok).collect())
    })
    .await
    .map_err(|err| SessionLoadError::Runtime(err.to_string()))?
}

fn dashboard_priority(item: &DashboardConversationItem) -> u8 {
  match item.list_status {
    SessionListStatus::Permission => 0,
    SessionListStatus::Question => 1,
    SessionListStatus::Working => 2,
    SessionListStatus::Reply => 3,
    SessionListStatus::Ended => 4,
  }
}

fn dashboard_grouping_details(
  project_path: &str,
  repository_root: Option<&str>,
  project_name: Option<&str>,
) -> (String, String) {
  let grouping_path = repository_root.unwrap_or(project_path).to_string();
  let grouping_name = project_name
    .map(str::trim)
    .filter(|name| !name.is_empty())
    .map(ToOwned::to_owned)
    .unwrap_or_else(|| {
      grouping_path
        .rsplit('/')
        .find(|segment| !segment.is_empty())
        .map(std::string::ToString::to_string)
        .unwrap_or_else(|| "Unknown".to_string())
    });

  (grouping_path, grouping_name)
}

fn sanitize_dashboard_text(text: &str) -> String {
  text
    .replace("**", "")
    .replace("__", "")
    .replace('`', "")
    .replace("## ", "")
    .replace("# ", "")
}

fn dashboard_preview_text(last_message: Option<&str>, context_line: Option<&str>) -> String {
  sanitize_dashboard_text(
    last_message
      .or(context_line)
      .unwrap_or("Waiting for your next message."),
  )
}

fn dashboard_activity_summary(
  pending_tool_name: Option<&str>,
  last_message: Option<&str>,
  context_line: Option<&str>,
) -> String {
  if let Some(tool_name) = pending_tool_name {
    return format!("Running {tool_name}");
  }

  sanitize_dashboard_text(last_message.or(context_line).unwrap_or("Processing…"))
}

fn format_tool_context(tool_name: &str, input: Option<&str>) -> String {
  let Some(input) = input.filter(|value| !value.is_empty()) else {
    return format!("Wants to run {tool_name}");
  };

  let Ok(json) = serde_json::from_str::<serde_json::Value>(input) else {
    return format!("Wants to run {tool_name}");
  };

  match tool_name {
    "Bash" => json
      .get("command")
      .and_then(serde_json::Value::as_str)
      .map(ToOwned::to_owned),
    "Edit" | "Write" | "Read" => json
      .get("file_path")
      .and_then(serde_json::Value::as_str)
      .and_then(|path| Path::new(path).file_name())
      .and_then(|name| name.to_str())
      .map(|name| format!("{tool_name} {name}")),
    "Grep" => json
      .get("pattern")
      .and_then(serde_json::Value::as_str)
      .map(|pattern| format!("Search for \"{pattern}\"")),
    "Glob" => json
      .get("pattern")
      .and_then(serde_json::Value::as_str)
      .map(|pattern| format!("Find files matching {pattern}")),
    _ => None,
  }
  .unwrap_or_else(|| format!("Wants to run {tool_name}"))
}

fn dashboard_alert_context(
  pending_question: Option<&str>,
  pending_tool_name: Option<&str>,
  pending_tool_input: Option<&str>,
  last_message: Option<&str>,
  context_line: Option<&str>,
) -> String {
  if let Some(question) = pending_question.filter(|value| !value.is_empty()) {
    return question.to_string();
  }

  if let Some(tool_name) = pending_tool_name {
    return format_tool_context(tool_name, pending_tool_input);
  }

  sanitize_dashboard_text(
    last_message
      .or(context_line)
      .unwrap_or("Needs your attention."),
  )
}

fn dashboard_diff_preview(diff: Option<&str>) -> Option<DashboardDiffPreview> {
  let diff = diff?.trim();
  if diff.is_empty() {
    return None;
  }

  let mut file_paths: Vec<String> = vec![];
  let mut additions = 0_u32;
  let mut deletions = 0_u32;

  for line in diff.lines() {
    if let Some(path) = line.strip_prefix("+++ b/") {
      let path = path.trim();
      if !path.is_empty() && !file_paths.iter().any(|existing| existing == path) {
        file_paths.push(path.to_string());
      }
      continue;
    }
    if let Some(rest) = line.strip_prefix("diff --git ") {
      if let Some(path) = rest.split(" b/").nth(1) {
        let path = path.trim();
        if !path.is_empty() && !file_paths.iter().any(|existing| existing == path) {
          file_paths.push(path.to_string());
        }
      }
      continue;
    }
    if line.starts_with('+') && !line.starts_with("+++") {
      additions = additions.saturating_add(1);
    } else if line.starts_with('-') && !line.starts_with("---") {
      deletions = deletions.saturating_add(1);
    }
  }

  Some(DashboardDiffPreview {
    file_count: file_paths.len() as u32,
    additions,
    deletions,
    file_paths: file_paths.into_iter().take(3).collect(),
  })
}

fn projection_display_context(
  projection: &PersistedDashboardProjection,
) -> (String, Option<String>) {
  let display_title = SessionSummary::display_title_from_parts(
    projection.custom_name.as_deref(),
    projection.summary.as_deref(),
    projection.first_prompt.as_deref(),
    projection.project_name.as_deref(),
    &projection.project_path,
  );
  let context_line = SessionSummary::context_line_from_parts(
    projection.summary.as_deref(),
    projection.first_prompt.as_deref(),
    projection.last_message.as_deref(),
  );
  (display_title, context_line)
}

fn projection_list_status(projection: &PersistedDashboardProjection) -> SessionListStatus {
  SessionSummary::list_status_from_parts(projection.status, projection.work_status)
}

fn is_direct_conversation(conversation: &DashboardConversationItem) -> bool {
  matches!(
    (
      conversation.provider,
      conversation.codex_integration_mode,
      conversation.claude_integration_mode
    ),
    (Provider::Codex, Some(CodexIntegrationMode::Direct), _)
      | (Provider::Claude, _, Some(ClaudeIntegrationMode::Direct))
  )
}

fn apply_page_to_session(session: &mut SessionState, page: &ConversationPage) {
  session.rows = page.rows.clone();
  session.total_row_count = page.total_row_count;
  session.has_more_before = page.has_more_before;
  session.oldest_sequence = page.oldest_sequence;
  session.newest_sequence = page.newest_sequence;
}

pub(crate) async fn load_dashboard_snapshot(
  state: &Arc<SessionRegistry>,
) -> Result<DashboardSnapshot, SessionLoadError> {
  let projections = load_persisted_dashboard_projections(state.db_path().clone()).await?;

  let mut sessions: Vec<SessionSummary> = projections
    .iter()
    .map(|projection| {
      let (display_title, context_line) = projection_display_context(projection);
      let list_status = projection_list_status(projection);

      SessionSummary {
        id: projection.id.clone(),
        provider: projection.provider,
        project_path: projection.project_path.clone(),
        transcript_path: None,
        project_name: projection.project_name.clone(),
        model: projection.model.clone(),
        custom_name: projection.custom_name.clone(),
        summary: projection.summary.clone(),
        first_prompt: projection.first_prompt.clone(),
        last_message: projection.last_message.clone(),
        status: projection.status,
        work_status: projection.work_status,
        control_mode: projection.control_mode,
        lifecycle_state: projection.lifecycle_state,
        accepts_user_input: projection.status == SessionStatus::Active
          && projection.control_mode == SessionControlMode::Direct
          && projection.lifecycle_state == SessionLifecycleState::Open,
        steerable: projection.work_status == WorkStatus::Working,
        token_usage: projection.token_usage.clone(),
        token_usage_snapshot_kind: projection.token_usage_snapshot_kind,
        has_pending_approval: projection.pending_approval_id.is_some(),
        codex_integration_mode: projection.codex_integration_mode,
        claude_integration_mode: projection.claude_integration_mode,
        approval_policy: projection.approval_policy.clone(),
        approval_policy_details: None,
        sandbox_mode: projection.sandbox_mode.clone(),
        permission_mode: projection.permission_mode.clone(),
        allow_bypass_permissions: projection.allow_bypass_permissions,
        collaboration_mode: projection.collaboration_mode.clone(),
        multi_agent: projection.multi_agent,
        personality: projection.personality.clone(),
        service_tier: projection.service_tier.clone(),
        developer_instructions: projection.developer_instructions.clone(),
        codex_config_mode: None,
        codex_config_profile: None,
        codex_model_provider: None,
        codex_config_source: None,
        codex_config_overrides: None,
        pending_tool_name: projection.pending_tool_name.clone(),
        pending_tool_input: projection.pending_tool_input.clone(),
        pending_question: projection.pending_question.clone(),
        pending_approval_id: projection.pending_approval_id.clone(),
        started_at: projection.started_at.clone(),
        last_activity_at: projection.last_activity_at.clone(),
        last_progress_at: None,
        git_branch: projection.git_branch.clone(),
        git_sha: None,
        current_cwd: None,
        effort: projection.effort.clone(),
        approval_version: Some(projection.approval_version),
        summary_revision: 0,
        repository_root: projection.repository_root.clone(),
        is_worktree: projection.is_worktree,
        worktree_id: projection.worktree_id.clone(),
        unread_count: projection.unread_count,
        has_turn_diff: has_turn_diff(projection.current_diff.as_deref()),
        display_title,
        context_line,
        list_status,
        active_worker_count: projection.active_worker_count,
        pending_tool_family: None,
        forked_from_session_id: projection.forked_from_session_id.clone(),
        mission_id: projection.mission_id.clone(),
        issue_identifier: projection.issue_identifier.clone(),
      }
    })
    .collect();

  sessions.sort_by(|lhs, rhs| {
    rhs
      .last_activity_at
      .cmp(&lhs.last_activity_at)
      .then_with(|| lhs.display_title.cmp(&rhs.display_title))
  });

  let mut conversations: Vec<DashboardConversationItem> = projections
    .iter()
    .filter(|projection| projection.status == SessionStatus::Active)
    .map(|projection| {
      let (display_title, context_line) = projection_display_context(projection);
      let list_status = projection_list_status(projection);
      let preview_text =
        dashboard_preview_text(projection.last_message.as_deref(), context_line.as_deref());
      let activity_summary = dashboard_activity_summary(
        projection.pending_tool_name.as_deref(),
        projection.last_message.as_deref(),
        context_line.as_deref(),
      );
      let alert_context = dashboard_alert_context(
        projection.pending_question.as_deref(),
        projection.pending_tool_name.as_deref(),
        projection.pending_tool_input.as_deref(),
        projection.last_message.as_deref(),
        context_line.as_deref(),
      );
      let (grouping_path, grouping_name) = dashboard_grouping_details(
        &projection.project_path,
        projection.repository_root.as_deref(),
        projection.project_name.as_deref(),
      );

      DashboardConversationItem {
        session_id: projection.id.clone(),
        provider: projection.provider,
        project_path: projection.project_path.clone(),
        grouping_path: Some(grouping_path),
        grouping_name: Some(grouping_name),
        project_name: projection.project_name.clone(),
        repository_root: projection.repository_root.clone(),
        git_branch: projection.git_branch.clone(),
        is_worktree: projection.is_worktree,
        worktree_id: projection.worktree_id.clone(),
        model: projection.model.clone(),
        codex_integration_mode: projection.codex_integration_mode,
        claude_integration_mode: projection.claude_integration_mode,
        status: projection.status,
        work_status: projection.work_status,
        control_mode: projection.control_mode,
        lifecycle_state: projection.lifecycle_state,
        list_status,
        display_title,
        context_line,
        last_message: projection.last_message.clone(),
        preview_text: Some(preview_text),
        activity_summary: Some(activity_summary),
        alert_context: Some(alert_context),
        started_at: projection.started_at.clone(),
        last_activity_at: projection.last_activity_at.clone(),
        unread_count: projection.unread_count,
        has_turn_diff: has_turn_diff(projection.current_diff.as_deref()),
        diff_preview: dashboard_diff_preview(projection.current_diff.as_deref()),
        pending_tool_name: projection.pending_tool_name.clone(),
        pending_tool_input: projection.pending_tool_input.clone(),
        pending_question: projection.pending_question.clone(),
        tool_count: projection.tool_count,
        active_worker_count: projection.active_worker_count,
        issue_identifier: projection.issue_identifier.clone(),
        effort: projection.effort.clone(),
      }
    })
    .collect();

  conversations.sort_by(|lhs, rhs| {
    dashboard_priority(lhs)
      .cmp(&dashboard_priority(rhs))
      .then_with(|| rhs.last_activity_at.cmp(&lhs.last_activity_at))
      .then_with(|| lhs.display_title.cmp(&rhs.display_title))
  });

  let counts = DashboardCounts {
    attention: conversations
      .iter()
      .filter(|conversation| {
        matches!(
          conversation.list_status,
          SessionListStatus::Permission | SessionListStatus::Question
        )
      })
      .count() as u32,
    running: conversations
      .iter()
      .filter(|conversation| matches!(conversation.list_status, SessionListStatus::Working))
      .count() as u32,
    ready: conversations
      .iter()
      .filter(|conversation| matches!(conversation.list_status, SessionListStatus::Reply))
      .count() as u32,
    direct: conversations
      .iter()
      .filter(|conversation| is_direct_conversation(conversation))
      .count() as u32,
  };

  Ok(DashboardSnapshot {
    revision: state.current_dashboard_revision(),
    sessions: sessions.iter().map(SessionListItem::from_summary).collect(),
    conversations,
    counts,
  })
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

  match load_session_by_id(session_id).await {
    Ok(Some(mut restored)) => {
      hydrate_restored_rows_if_missing(&mut restored, session_id).await;
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
  match load_session_metadata_by_id(session_id).await {
    Ok(Some(restored)) => {
      let page = load_conversation_page(session_id, None, limit).await?;

      let mut session = restored_session_to_state(restored);
      apply_page_to_session(&mut session, &page);
      if let Some(actor) = state.get_session(session_id) {
        session.revision = Some(actor.snapshot().revision);
      }
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

pub(crate) async fn load_full_session_state(
  state: &Arc<SessionRegistry>,
  session_id: &str,
  include_messages: bool,
) -> Result<SessionState, SessionLoadError> {
  let restored_result = if include_messages {
    load_session_by_id(session_id).await
  } else {
    load_session_metadata_by_id(session_id).await
  };

  match restored_result {
    Ok(Some(mut restored)) => {
      if include_messages {
        hydrate_restored_rows_if_missing(&mut restored, session_id).await;
      }

      let mut snapshot = restored_session_to_state(restored);
      if !include_messages {
        snapshot.rows.clear();
        snapshot.oldest_sequence = None;
        snapshot.newest_sequence = None;
      }
      if let Some(actor) = state.get_session(session_id) {
        snapshot.revision = Some(actor.snapshot().revision);
      }
      hydrate_subagents(&mut snapshot, session_id).await;
      Ok(snapshot)
    }
    Ok(None) => Err(SessionLoadError::NotFound),
    Err(err) => Err(SessionLoadError::Db(err.to_string())),
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
