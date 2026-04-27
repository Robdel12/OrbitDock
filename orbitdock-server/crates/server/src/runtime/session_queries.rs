use std::sync::Arc;

use crate::infrastructure::db_pool::ReadPool;
use crate::infrastructure::usage_pricing::estimate_session_cost as estimate_live_session_cost;
use orbitdock_protocol::{
  ClaudeIntegrationMode, CodexIntegrationMode, LibrarySnapshot, Provider, SessionControlMode,
  SessionLifecycleState, SessionListItem, SessionListStatus, SessionState, SessionStatus,
  SessionSummary, TokenUsage, WorkStatus,
};
use tracing::warn;

use crate::domain::sessions::conversation::{ConversationBootstrap, ConversationPage};
use crate::domain::sessions::session::steerable_from_parts;
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
  let status = parse_status(&row.get::<_, String>(2)?);
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

/// Load a page of all sessions for the library view, with SQL-level pagination.
async fn load_library_projections(
  pool: Arc<ReadPool>,
  limit: usize,
  offset: usize,
) -> Result<(Vec<PersistedDashboardProjection>, u64), SessionLoadError> {
  tokio::task::spawn_blocking(
    move || -> Result<(Vec<PersistedDashboardProjection>, u64), SessionLoadError> {
      let conn = pool
        .get()
        .map_err(|err| SessionLoadError::Db(err.to_string()))?;

      let total: u64 = conn
        .query_row("SELECT COUNT(*) FROM sessions", [], |row| row.get(0))
        .map_err(|err| SessionLoadError::Db(err.to_string()))?;

      let sql = format!(
        "{PROJECTION_SELECT}
         ORDER BY COALESCE(s.last_activity_at, s.started_at) DESC
         LIMIT ?1 OFFSET ?2"
      );
      let mut stmt = conn
        .prepare(&sql)
        .map_err(|err| SessionLoadError::Db(err.to_string()))?;

      let rows = stmt
        .query_map(
          rusqlite::params![limit as i64, offset as i64],
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

fn apply_page_to_session(session: &mut SessionState, page: &ConversationPage) {
  session.rows = page.rows.clone();
  session.total_row_count = page.total_row_count;
  session.has_more_before = page.has_more_before;
  session.oldest_sequence = page.oldest_sequence;
  session.newest_sequence = page.newest_sequence;
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
) -> Result<LibrarySnapshot, SessionLoadError> {
  let (projections, total_count) =
    load_library_projections(Arc::clone(state.read_pool()), limit, offset).await?;

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
  if let Some(actor) = state.get_session(session_id) {
    if let (Ok(mut session), Ok(page)) = (
      actor.retained_state().await,
      actor.conversation_page(None, limit).await,
    ) {
      let page = expand_conversation_page(session_id, page, limit).await?;

      strip_diff_payloads(&mut session);
      apply_page_to_session(&mut session, &page);
      hydrate_subagents(&mut session, session_id).await;

      return Ok(ConversationBootstrap {
        session,
        total_row_count: page.total_row_count,
        has_more_before: page.has_more_before,
        oldest_sequence: page.oldest_sequence,
        newest_sequence: page.newest_sequence,
      });
    }

    warn!(
      component = "api",
      event = "api.get_conversation.runtime_state_unavailable",
      session_id = %session_id,
      "Falling back to persisted conversation bootstrap"
    );
  }

  match load_session_metadata_by_id(session_id).await {
    Ok(Some(restored)) => {
      let page = load_conversation_page(session_id, None, limit).await?;

      let mut session = restored_session_to_state(restored);
      strip_diff_payloads(&mut session);
      apply_page_to_session(&mut session, &page);
      hydrate_ephemeral_state(&mut session, state, session_id).await;
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
  include_diffs: bool,
) -> Result<SessionState, SessionLoadError> {
  match load_persisted_session_state(session_id, include_messages, include_diffs).await {
    Ok(mut snapshot) => {
      hydrate_ephemeral_state(&mut snapshot, state, session_id).await;
      hydrate_subagents(&mut snapshot, session_id).await;
      Ok(snapshot)
    }
    Err(SessionLoadError::NotFound) => {
      let Some(actor) = state.get_session(session_id) else {
        return Err(SessionLoadError::NotFound);
      };

      let mut snapshot = actor
        .retained_state()
        .await
        .map_err(SessionLoadError::Runtime)?;
      trim_session_payload(&mut snapshot, include_messages, include_diffs);
      hydrate_ephemeral_state(&mut snapshot, state, session_id).await;
      hydrate_subagents(&mut snapshot, session_id).await;
      Ok(snapshot)
    }
    Err(err) => Err(err),
  }
}

pub(crate) async fn load_persisted_session_state(
  session_id: &str,
  include_messages: bool,
  include_diffs: bool,
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
      trim_session_payload(&mut snapshot, include_messages, include_diffs);
      Ok(snapshot)
    }
    Ok(None) => Err(SessionLoadError::NotFound),
    Err(err) => Err(SessionLoadError::Db(err.to_string())),
  }
}

/// Load the light, client-facing session metadata projection.
///
/// This is the safe API boundary for endpoints that need session metadata but
/// not conversation rows or diff payloads. It keeps the transport payload cheap
/// and applies the same live affordance hydration as detail snapshots.
pub(crate) async fn load_light_session_state(
  state: &Arc<SessionRegistry>,
  session_id: &str,
) -> Result<SessionState, SessionLoadError> {
  match load_full_session_state(state, session_id, false, false).await {
    Ok(session) => Ok(session),
    Err(SessionLoadError::NotFound) => {
      let Some(actor) = state.get_session(session_id) else {
        return Err(SessionLoadError::NotFound);
      };

      let mut session = actor
        .retained_state()
        .await
        .map_err(SessionLoadError::Runtime)?;
      trim_session_payload(&mut session, false, false);
      session.total_row_count = 0;
      session.has_more_before = false;
      hydrate_ephemeral_state(&mut session, state, session_id).await;
      hydrate_subagents(&mut session, session_id).await;
      Ok(session)
    }
    Err(error) => Err(error),
  }
}

fn trim_session_payload(session: &mut SessionState, include_messages: bool, include_diffs: bool) {
  if !include_diffs {
    strip_diff_payloads(session);
  }
  if !include_messages {
    session.rows.clear();
    session.oldest_sequence = None;
    session.newest_sequence = None;
  }
}

/// Hydrate runtime state from the live session actor.
/// The DB may lag batched writes, so the actor is the real-time source of truth
/// for control affordances and other active-session fields.
async fn hydrate_ephemeral_state(
  session: &mut SessionState,
  registry: &Arc<SessionRegistry>,
  session_id: &str,
) {
  if let Some(actor) = registry.get_session(session_id) {
    if let Ok(live) = actor.retained_state().await {
      let connector_attached = direct_connector_attached(registry, session_id, live.provider);

      session.revision = live.revision;
      session.status = live.status;
      session.work_status = live.work_status;
      session.control_mode = live.control_mode;
      session.lifecycle_state = live.lifecycle_state;
      session.connector_attached = connector_attached;
      session.accepts_user_input = live.accepts_user_input && connector_attached;
      session.steerable = live.steerable && connector_attached;
      session.can_interrupt = live.can_interrupt && connector_attached;
      session.pending_approval = live.pending_approval;
      session.permission_mode = live.permission_mode;
      session.pending_tool_name = live.pending_tool_name;
      session.pending_tool_input = live.pending_tool_input;
      session.pending_question = live.pending_question;
      session.pending_approval_id = live.pending_approval_id;
      session.approval_version = live.approval_version;
      session.current_turn_id = live.current_turn_id;
      session.git_branch = live.git_branch;
      session.current_cwd = live.current_cwd;
      session.token_usage = live.token_usage;
      session.token_usage_snapshot_kind = live.token_usage_snapshot_kind;
    }
  }
}

fn direct_connector_attached(
  registry: &Arc<SessionRegistry>,
  session_id: &str,
  provider: Provider,
) -> bool {
  match provider {
    Provider::Codex => registry
      .get_codex_action_tx(session_id)
      .is_some_and(|tx| !tx.is_closed()),
    Provider::Claude => registry
      .get_claude_action_tx(session_id)
      .is_some_and(|tx| !tx.is_closed()),
  }
}

fn strip_diff_payloads(state: &mut SessionState) {
  state.current_diff = None;
  state.cumulative_diff = None;
  state.turn_diffs.clear();
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

#[cfg(test)]
#[path = "session_queries_tests.rs"]
mod session_queries_tests;
