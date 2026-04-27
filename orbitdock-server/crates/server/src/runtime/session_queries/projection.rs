use std::sync::Arc;

use crate::domain::sessions::session::steerable_from_parts;
use crate::infrastructure::db_pool::ReadPool;
use crate::infrastructure::persistence::snapshot_kind_from_str;
use crate::infrastructure::usage_pricing::estimate_session_cost as estimate_live_session_cost;
use crate::runtime::restored_sessions::{parse_provider, parse_session_status, parse_work_status};
use crate::runtime::session_registry::SessionRegistry;
use orbitdock_protocol::{
  ClaudeIntegrationMode, CodexIntegrationMode, LibrarySnapshot, Provider, SessionControlMode,
  SessionLifecycleState, SessionListItem, SessionListStatus, SessionStatus, SessionSummary,
  TokenUsage, WorkStatus,
};

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

/// Shared SELECT columns for dashboard/library projection queries.
/// Column indexes 0–44 are stable — row mappers depend on this order.
const PROJECTION_SELECT: &str = "SELECT s.id,
                  s.provider,
                  s.status,
                  s.work_status,
                  s.control_mode,
                  COALESCE(s.lifecycle_state, CASE WHEN s.status = 'ended' THEN 'ended' ELSE 'open' END),
                  s.project_path,
                  s.project_name,
                  s.repository_root,
                  s.git_branch,
                  COALESCE(s.is_worktree, 0),
                  s.worktree_id,
                  s.model,
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
                  COALESCE(sa.cnt, 0),
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
                  COALESCE(uss.snapshot_input_tokens, 0),
                  COALESCE(uss.snapshot_output_tokens, 0),
                  COALESCE(uss.snapshot_cached_tokens, 0),
                  COALESCE(uss.snapshot_context_window, 0),
                  COALESCE(uss.snapshot_kind, 'unknown'),
                  s.pending_approval_id,
                  s.mission_id,
                  COALESCE(s.allow_bypass_permissions, 0),
                  s.forked_from_session_id,
                  COALESCE(s.approval_version, 0)
           FROM sessions s
           LEFT JOIN usage_session_state uss ON uss.session_id = s.id
           LEFT JOIN (
               SELECT session_id, COUNT(*) as cnt
               FROM subagents WHERE status = 'running'
               GROUP BY session_id
           ) sa ON sa.session_id = s.id";

fn map_projection_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<PersistedDashboardProjection> {
  let provider = parse_provider(&row.get::<_, String>(1)?);
  let status = parse_session_status(None, &row.get::<_, String>(2)?);
  let work_status = parse_work_status(status, &row.get::<_, String>(3)?);
  let control_mode = parse_control_mode(&row.get::<_, String>(4)?);
  let lifecycle_state = parse_lifecycle_state(&row.get::<_, String>(5)?);
  let (codex_integration_mode, claude_integration_mode) =
    normalize_integration_modes(provider, control_mode);

  let multi_agent: Option<i64> = row.get(31)?;
  let input_tokens: i64 = row.get(35)?;
  let output_tokens: i64 = row.get(36)?;
  let cached_tokens: i64 = row.get(37)?;
  let context_window: i64 = row.get(38)?;
  let snapshot_kind: String = row.get(39)?;

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
    custom_name: row.get(13)?,
    summary: row.get(14)?,
    first_prompt: row.get(15)?,
    last_message: row.get(16)?,
    started_at: row.get(17)?,
    last_activity_at: row.get(18)?,
    unread_count: row.get::<_, i64>(19)?.max(0) as u64,
    current_diff: row.get(20)?,
    pending_tool_name: row.get(21)?,
    pending_tool_input: row.get(22)?,
    pending_question: row.get(23)?,
    active_worker_count: row.get::<_, i64>(24)?.max(0) as u32,
    issue_identifier: row.get(25)?,
    effort: row.get(26)?,
    approval_policy: row.get(27)?,
    sandbox_mode: row.get(28)?,
    permission_mode: row.get(29)?,
    collaboration_mode: row.get(30)?,
    multi_agent: multi_agent.map(|value| value != 0),
    personality: row.get(32)?,
    service_tier: row.get(33)?,
    developer_instructions: row.get(34)?,
    token_usage: TokenUsage {
      input_tokens: input_tokens.max(0) as u64,
      output_tokens: output_tokens.max(0) as u64,
      cached_tokens: cached_tokens.max(0) as u64,
      context_window: context_window.max(0) as u64,
    },
    token_usage_snapshot_kind: snapshot_kind_from_str(Some(snapshot_kind.as_str())),
    pending_approval_id: row.get(40)?,
    mission_id: row.get(41)?,
    allow_bypass_permissions: row.get::<_, i64>(42)? != 0,
    forked_from_session_id: row.get(43)?,
    approval_version: row.get::<_, i64>(44)?.max(0) as u64,
  })
}

fn normalized_timestamp_sql(column: &str) -> String {
  format!(
    "CASE
       WHEN {column} IS NULL OR TRIM({column}) = '' THEN NULL
       WHEN INSTR({column}, 'T') > 0 THEN CAST(strftime('%s', {column}) AS INTEGER)
       ELSE CAST(REPLACE({column}, 'Z', '') AS INTEGER)
     END"
  )
}

fn library_activity_sort_sql() -> String {
  let last_activity = normalized_timestamp_sql("s.last_activity_at");
  let ended_at = normalized_timestamp_sql("s.ended_at");
  let last_progress = normalized_timestamp_sql("s.last_progress_at");
  let started_at = normalized_timestamp_sql("s.started_at");

  format!(
    "MAX(
       COALESCE({last_activity}, 0),
       COALESCE({ended_at}, 0),
       COALESCE({last_progress}, 0),
       COALESCE({started_at}, 0)
     )"
  )
}

fn escape_like_query(value: &str) -> String {
  let mut escaped = String::with_capacity(value.len());
  for ch in value.chars() {
    match ch {
      '%' | '_' | '\\' => {
        escaped.push('\\');
        escaped.push(ch);
      }
      _ => escaped.push(ch),
    }
  }
  escaped
}

/// Load a page of all sessions for the library view, with SQL-level pagination.
async fn load_library_projections(
  pool: Arc<ReadPool>,
  limit: usize,
  offset: usize,
  query: Option<String>,
) -> Result<(Vec<PersistedDashboardProjection>, u64), SessionLoadError> {
  tokio::task::spawn_blocking(
    move || -> Result<(Vec<PersistedDashboardProjection>, u64), SessionLoadError> {
      let conn = pool
        .get()
        .map_err(|err| SessionLoadError::Db(err.to_string()))?;

      let search_query = query.map(|value| format!("%{}%", escape_like_query(&value.to_lowercase())));
      let filter_sql = "\
        WHERE :query IS NULL
           OR LOWER(s.id) LIKE :query ESCAPE '\\'
           OR LOWER(COALESCE(s.custom_name, '')) LIKE :query ESCAPE '\\'
           OR LOWER(COALESCE(s.summary, '')) LIKE :query ESCAPE '\\'
           OR LOWER(COALESCE(s.first_prompt, '')) LIKE :query ESCAPE '\\'
           OR LOWER(COALESCE(s.last_message, '')) LIKE :query ESCAPE '\\'
           OR LOWER(COALESCE(s.project_name, '')) LIKE :query ESCAPE '\\'
           OR LOWER(COALESCE(s.project_path, '')) LIKE :query ESCAPE '\\'
           OR LOWER(COALESCE(s.repository_root, '')) LIKE :query ESCAPE '\\'
           OR LOWER(COALESCE(s.git_branch, '')) LIKE :query ESCAPE '\\'
           OR LOWER(COALESCE(s.model, '')) LIKE :query ESCAPE '\\'
           OR LOWER(COALESCE(s.issue_identifier, '')) LIKE :query ESCAPE '\\'";
      let count_sql = format!("SELECT COUNT(*) FROM sessions s {filter_sql}");
      let total: u64 = conn
        .query_row(
          &count_sql,
          rusqlite::named_params! { ":query": search_query.as_deref() },
          |row| row.get(0),
        )
        .map_err(|err| SessionLoadError::Db(err.to_string()))?;

      let activity_sort_sql = library_activity_sort_sql();
      let sql = format!(
        "{PROJECTION_SELECT}
         {filter_sql}
         ORDER BY {activity_sort_sql} DESC, s.id DESC
         LIMIT :limit OFFSET :offset"
      );
      let mut stmt = conn
        .prepare(&sql)
        .map_err(|err| SessionLoadError::Db(err.to_string()))?;

      let rows = stmt
        .query_map(
          rusqlite::named_params! {
            ":query": search_query.as_deref(),
            ":limit": limit as i64,
            ":offset": offset as i64,
          },
          map_projection_row,
        )
        .map_err(|err| SessionLoadError::Db(err.to_string()))?;

      Ok((rows.filter_map(Result::ok).collect(), total))
    },
  )
  .await
  .map_err(|err| SessionLoadError::Runtime(err.to_string()))?
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

fn session_summary_from_projection(projection: &PersistedDashboardProjection) -> SessionSummary {
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
    steerable: steerable_from_parts(
      projection.status,
      projection.work_status,
      projection.control_mode,
      projection.lifecycle_state,
    ),
    token_usage: projection.token_usage.clone(),
    token_usage_snapshot_kind: projection.token_usage_snapshot_kind,
    has_pending_approval: projection.pending_approval_id.is_some(),
    codex_integration_mode: projection.codex_integration_mode,
    claude_integration_mode: projection.claude_integration_mode,
    approval_policy: projection.approval_policy.clone(),
    approval_policy_details: None,
    sandbox_mode: projection.sandbox_mode.clone(),
    sandbox_policy_details: None,
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
}

fn session_list_item_from_summary(summary: &SessionSummary) -> SessionListItem {
  let mut item = SessionListItem::from_summary(summary);
  item.total_cost_usd = estimate_live_session_cost(
    summary.provider,
    summary.model.as_deref(),
    &summary.token_usage,
  );
  item
}

pub(crate) async fn load_library_snapshot(
  state: &Arc<SessionRegistry>,
  limit: usize,
  offset: usize,
  query: Option<&str>,
) -> Result<LibrarySnapshot, SessionLoadError> {
  let (projections, total_count) =
    load_library_projections(
      Arc::clone(state.read_pool()),
      limit,
      offset,
      query.map(str::to_string),
    )
    .await?;

  let sessions: Vec<SessionSummary> = projections
    .iter()
    .map(session_summary_from_projection)
    .collect();

  let page_count = sessions.len();
  let next_offset = if offset.saturating_add(page_count) < total_count as usize {
    Some((offset + page_count) as u64)
  } else {
    None
  };

  Ok(LibrarySnapshot {
    revision: state.current_library_revision(),
    sessions: sessions
      .iter()
      .map(session_list_item_from_summary)
      .collect(),
    next_offset,
    total_count,
  })
}
