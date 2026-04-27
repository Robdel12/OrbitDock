use std::collections::HashSet;

use orbitdock_protocol::{
  conversation_contracts::{extract_row_content_str_summary, ConversationRowSummary},
  ConversationSnapshotPage, Provider, SessionDetailSnapshot, SessionListItem, SessionState,
  SessionStatus, SessionSummary, WorkStatus,
};
use serde::Serialize;

use crate::output::{relative_time_label, truncate};

#[derive(Debug, Serialize)]
pub(crate) struct SessionJsonOverview {
  id: String,
  provider: &'static str,
  project_path: String,
  #[serde(skip_serializing_if = "Option::is_none")]
  project_name: Option<String>,
  project_label: String,
  #[serde(skip_serializing_if = "Option::is_none")]
  model: Option<String>,
  title: String,
  #[serde(skip_serializing_if = "Option::is_none")]
  context_line: Option<String>,
  status: &'static str,
  work_status: &'static str,
  #[serde(skip_serializing_if = "Option::is_none")]
  list_status: Option<&'static str>,
  control_mode: &'static str,
  lifecycle_state: &'static str,
  #[serde(skip_serializing_if = "Option::is_none")]
  accepts_user_input: Option<bool>,
  steerable: bool,
  #[serde(skip_serializing_if = "Option::is_none")]
  permission_mode: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  approval_policy: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  effort: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pending_tool_name: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pending_question: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  git_branch: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  git_sha: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  repository_root: Option<String>,
  is_worktree: bool,
  #[serde(skip_serializing_if = "Option::is_none")]
  worktree_id: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  started_at: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  last_activity_at: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  last_progress_at: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  activity_label: Option<String>,
  input_tokens: u64,
  output_tokens: u64,
  cached_tokens: u64,
  #[serde(skip_serializing_if = "Option::is_none")]
  total_tokens: Option<u64>,
  #[serde(skip_serializing_if = "Option::is_none")]
  total_cost_usd: Option<f64>,
  #[serde(skip_serializing_if = "Option::is_none")]
  context_window: Option<u64>,
  #[serde(skip_serializing_if = "Option::is_none")]
  context_fill_percent: Option<f64>,
  #[serde(skip_serializing_if = "Option::is_none")]
  token_usage_snapshot_kind: Option<&'static str>,
  #[serde(skip_serializing_if = "Option::is_none")]
  cache_hit_percent: Option<f64>,
  unread_count: u64,
}

#[derive(Debug, Serialize)]
pub(crate) struct SessionListJsonResponse {
  kind: &'static str,
  count: usize,
  sessions: Vec<SessionListItem>,
  summaries: Vec<SessionJsonOverview>,
}

#[derive(Debug, Serialize)]
pub(crate) struct SessionConversationJsonSummary {
  requested: bool,
  included: bool,
  row_count: u64,
  has_more_before: bool,
  #[serde(skip_serializing_if = "Option::is_none")]
  oldest_sequence: Option<u64>,
  #[serde(skip_serializing_if = "Option::is_none")]
  newest_sequence: Option<u64>,
}

#[derive(Debug, Serialize)]
pub(crate) struct SessionDetailJsonResponse {
  kind: &'static str,
  revision: u64,
  session: SessionState,
  summary: SessionJsonOverview,
  conversation: SessionConversationJsonSummary,
}

#[derive(Debug, Serialize)]
pub(crate) struct SessionActionJsonResponse {
  pub(crate) ok: bool,
  pub(crate) action: &'static str,
  pub(crate) session_id: String,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub(crate) source_session_id: Option<String>,
  pub(crate) session: SessionSummary,
  pub(crate) summary: SessionJsonOverview,
}

pub(crate) fn pending_request_id(session: &SessionState) -> Option<&str> {
  session.pending_approval.as_ref().map(|req| req.id.as_str())
}

pub(crate) fn provider_str(p: &Provider) -> &'static str {
  match p {
    Provider::Claude => "claude",
    Provider::Codex => "codex",
  }
}

pub(crate) fn project_label(project_name: Option<&str>, project_path: &str) -> String {
  project_name
    .filter(|value| !value.trim().is_empty())
    .map(ToString::to_string)
    .or_else(|| {
      project_path
        .split('/')
        .next_back()
        .filter(|value| !value.trim().is_empty())
        .map(ToString::to_string)
    })
    .unwrap_or_else(|| "-".to_string())
}

pub(crate) fn session_status_str(s: &SessionStatus) -> &'static str {
  match s {
    SessionStatus::Active => "active",
    SessionStatus::Ended => "ended",
  }
}

pub(crate) fn work_status_str(s: &WorkStatus) -> &'static str {
  match s {
    WorkStatus::Working => "working",
    WorkStatus::Waiting => "waiting",
    WorkStatus::Permission => "permission",
    WorkStatus::Question => "question",
    WorkStatus::Reply => "reply",
    WorkStatus::Ended => "ended",
  }
}

pub(crate) fn list_status_str(s: &orbitdock_protocol::SessionListStatus) -> &'static str {
  match s {
    orbitdock_protocol::SessionListStatus::Working => "working",
    orbitdock_protocol::SessionListStatus::Permission => "permission",
    orbitdock_protocol::SessionListStatus::Question => "question",
    orbitdock_protocol::SessionListStatus::Reply => "reply",
    orbitdock_protocol::SessionListStatus::Ended => "ended",
  }
}

pub(crate) fn control_mode_str(s: &orbitdock_protocol::SessionControlMode) -> &'static str {
  match s {
    orbitdock_protocol::SessionControlMode::Direct => "direct",
    orbitdock_protocol::SessionControlMode::Passive => "passive",
  }
}

pub(crate) fn lifecycle_state_str(s: &orbitdock_protocol::SessionLifecycleState) -> &'static str {
  match s {
    orbitdock_protocol::SessionLifecycleState::Open => "open",
    orbitdock_protocol::SessionLifecycleState::Resumable => "resumable",
    orbitdock_protocol::SessionLifecycleState::Ended => "ended",
  }
}

pub(crate) fn token_usage_snapshot_kind_str(
  kind: orbitdock_protocol::TokenUsageSnapshotKind,
) -> &'static str {
  match kind {
    orbitdock_protocol::TokenUsageSnapshotKind::Unknown => "unknown",
    orbitdock_protocol::TokenUsageSnapshotKind::ContextTurn => "context_turn",
    orbitdock_protocol::TokenUsageSnapshotKind::LifetimeTotals => "lifetime_totals",
    orbitdock_protocol::TokenUsageSnapshotKind::Mixed => "mixed",
    orbitdock_protocol::TokenUsageSnapshotKind::CompactionReset => "compaction_reset",
  }
}

pub(crate) fn detail_preview(value: &str) -> String {
  let flattened = value.split_whitespace().collect::<Vec<_>>().join(" ");
  truncate(&flattened, 160)
}

pub(crate) fn compact_context_line(value: Option<&str>) -> Option<String> {
  value.map(detail_preview)
}

pub(crate) fn trusted_cache_hit_percent(input_tokens: u64, cached_tokens: u64) -> Option<f64> {
  if input_tokens == 0 || cached_tokens > input_tokens {
    return None;
  }
  Some((cached_tokens as f64 / input_tokens as f64) * 100.0)
}

pub(crate) fn session_json_overview_from_list_item(
  session: &SessionListItem,
) -> SessionJsonOverview {
  SessionJsonOverview {
    id: session.id.clone(),
    provider: provider_str(&session.provider),
    project_path: session.project_path.clone(),
    project_name: session.project_name.clone(),
    project_label: project_label(session.project_name.as_deref(), &session.project_path),
    model: session.model.clone(),
    title: session.display_title.clone(),
    context_line: compact_context_line(session.context_line.as_deref()),
    status: session_status_str(&session.status),
    work_status: work_status_str(&session.work_status),
    list_status: Some(list_status_str(&session.list_status)),
    control_mode: control_mode_str(&session.control_mode),
    lifecycle_state: lifecycle_state_str(&session.lifecycle_state),
    accepts_user_input: None,
    steerable: session.steerable,
    permission_mode: None,
    approval_policy: None,
    effort: session.effort.clone(),
    pending_tool_name: session.pending_tool_name.clone(),
    pending_question: None,
    git_branch: session.git_branch.clone(),
    git_sha: None,
    repository_root: session.repository_root.clone(),
    is_worktree: session.is_worktree,
    worktree_id: session.worktree_id.clone(),
    started_at: session.started_at.clone(),
    last_activity_at: session.last_activity_at.clone(),
    last_progress_at: session.last_progress_at.clone(),
    activity_label: relative_time_label(
      session
        .last_activity_at
        .as_deref()
        .or(session.started_at.as_deref()),
    ),
    input_tokens: session.input_tokens,
    output_tokens: session.output_tokens,
    cached_tokens: session.cached_tokens,
    total_tokens: Some(session.total_tokens),
    total_cost_usd: Some(session.total_cost_usd),
    context_window: None,
    context_fill_percent: None,
    token_usage_snapshot_kind: None,
    cache_hit_percent: None,
    unread_count: session.unread_count,
  }
}

pub(crate) fn session_json_overview_from_summary(session: &SessionSummary) -> SessionJsonOverview {
  SessionJsonOverview {
    id: session.id.clone(),
    provider: provider_str(&session.provider),
    project_path: session.project_path.clone(),
    project_name: session.project_name.clone(),
    project_label: project_label(session.project_name.as_deref(), &session.project_path),
    model: session.model.clone(),
    title: session.display_title.clone(),
    context_line: compact_context_line(session.context_line.as_deref()),
    status: session_status_str(&session.status),
    work_status: work_status_str(&session.work_status),
    list_status: Some(list_status_str(&session.list_status)),
    control_mode: control_mode_str(&session.control_mode),
    lifecycle_state: lifecycle_state_str(&session.lifecycle_state),
    accepts_user_input: Some(session.accepts_user_input),
    steerable: session.steerable,
    permission_mode: session.permission_mode.clone(),
    approval_policy: session.approval_policy.clone(),
    effort: session.effort.clone(),
    pending_tool_name: session.pending_tool_name.clone(),
    pending_question: session.pending_question.clone(),
    git_branch: session.git_branch.clone(),
    git_sha: session.git_sha.clone(),
    repository_root: session.repository_root.clone(),
    is_worktree: session.is_worktree,
    worktree_id: session.worktree_id.clone(),
    started_at: session.started_at.clone(),
    last_activity_at: session.last_activity_at.clone(),
    last_progress_at: session.last_progress_at.clone(),
    activity_label: relative_time_label(
      session
        .last_activity_at
        .as_deref()
        .or(session.started_at.as_deref()),
    ),
    input_tokens: session.token_usage.input_tokens,
    output_tokens: session.token_usage.output_tokens,
    cached_tokens: session.token_usage.cached_tokens,
    total_tokens: Some(session.token_usage.input_tokens + session.token_usage.output_tokens),
    total_cost_usd: None,
    context_window: Some(session.token_usage.context_window),
    context_fill_percent: Some(session.token_usage.context_fill_percent()),
    token_usage_snapshot_kind: Some(token_usage_snapshot_kind_str(
      session.token_usage_snapshot_kind,
    )),
    cache_hit_percent: trusted_cache_hit_percent(
      session.token_usage.input_tokens,
      session.token_usage.cached_tokens,
    ),
    unread_count: session.unread_count,
  }
}

pub(crate) fn session_json_overview_from_state(session: &SessionState) -> SessionJsonOverview {
  SessionJsonOverview {
    id: session.id.clone(),
    provider: provider_str(&session.provider),
    project_path: session.project_path.clone(),
    project_name: session.project_name.clone(),
    project_label: project_label(session.project_name.as_deref(), &session.project_path),
    model: session.model.clone(),
    title: SessionSummary::display_title_from_parts(
      session.custom_name.as_deref(),
      session.summary.as_deref(),
      session.first_prompt.as_deref(),
      session.project_name.as_deref(),
      &session.project_path,
    ),
    context_line: compact_context_line(
      SessionSummary::context_line_from_parts(
        session.summary.as_deref(),
        session.first_prompt.as_deref(),
        session.last_message.as_deref(),
      )
      .as_deref(),
    ),
    status: session_status_str(&session.status),
    work_status: work_status_str(&session.work_status),
    list_status: None,
    control_mode: control_mode_str(&session.control_mode),
    lifecycle_state: lifecycle_state_str(&session.lifecycle_state),
    accepts_user_input: Some(session.accepts_user_input),
    steerable: session.steerable,
    permission_mode: session.permission_mode.clone(),
    approval_policy: session.approval_policy.clone(),
    effort: session.effort.clone(),
    pending_tool_name: session.pending_tool_name.clone(),
    pending_question: session.pending_question.clone(),
    git_branch: session.git_branch.clone(),
    git_sha: session.git_sha.clone(),
    repository_root: session.repository_root.clone(),
    is_worktree: session.is_worktree,
    worktree_id: session.worktree_id.clone(),
    started_at: session.started_at.clone(),
    last_activity_at: session.last_activity_at.clone(),
    last_progress_at: session.last_progress_at.clone(),
    activity_label: relative_time_label(
      session
        .last_activity_at
        .as_deref()
        .or(session.started_at.as_deref()),
    ),
    input_tokens: session.token_usage.input_tokens,
    output_tokens: session.token_usage.output_tokens,
    cached_tokens: session.token_usage.cached_tokens,
    total_tokens: Some(session.token_usage.input_tokens + session.token_usage.output_tokens),
    total_cost_usd: None,
    context_window: Some(session.token_usage.context_window),
    context_fill_percent: Some(session.token_usage.context_fill_percent()),
    token_usage_snapshot_kind: Some(token_usage_snapshot_kind_str(
      session.token_usage_snapshot_kind,
    )),
    cache_hit_percent: trusted_cache_hit_percent(
      session.token_usage.input_tokens,
      session.token_usage.cached_tokens,
    ),
    unread_count: session.unread_count,
  }
}

pub(crate) fn build_session_list_json_response(
  sessions: Vec<SessionListItem>,
) -> SessionListJsonResponse {
  let summaries = sessions
    .iter()
    .map(session_json_overview_from_list_item)
    .collect();
  SessionListJsonResponse {
    kind: "session_list",
    count: sessions.len(),
    sessions,
    summaries,
  }
}

pub(crate) fn build_session_detail_json_response(
  snapshot: SessionDetailSnapshot,
  messages_requested: bool,
) -> SessionDetailJsonResponse {
  let conversation = SessionConversationJsonSummary {
    requested: messages_requested,
    included: messages_requested && !snapshot.session.rows.is_empty(),
    row_count: snapshot.session.total_row_count,
    has_more_before: snapshot.session.has_more_before,
    oldest_sequence: snapshot.session.oldest_sequence,
    newest_sequence: snapshot.session.newest_sequence,
  };
  let summary = session_json_overview_from_state(&snapshot.session);
  SessionDetailJsonResponse {
    kind: "session_detail",
    revision: snapshot.revision,
    session: snapshot.session,
    summary,
    conversation,
  }
}

pub(crate) fn conversation_snapshot_from_session(
  session: &SessionState,
) -> Option<ConversationSnapshotPage> {
  if session.rows.is_empty() {
    return None;
  }

  Some(ConversationSnapshotPage {
    replay_cursor: session.revision.unwrap_or_default(),
    session_id: session.id.clone(),
    rows: session.rows.iter().map(|row| row.to_summary()).collect(),
    total_row_count: session.total_row_count,
    has_more_before: session.has_more_before,
    forked_from_session_id: session.forked_from_session_id.clone(),
    oldest_sequence: session.oldest_sequence,
    newest_sequence: session.newest_sequence,
  })
}

pub(crate) fn format_row_type_summary(row: &ConversationRowSummary) -> &'static str {
  match row {
    ConversationRowSummary::User(_) => "user",
    ConversationRowSummary::Assistant(_) => "assistant",
    ConversationRowSummary::Tool(_) => "tool",
    ConversationRowSummary::Thinking(_) => "thinking",
    ConversationRowSummary::System(_) => "system",
    ConversationRowSummary::Worker(_) => "worker",
    ConversationRowSummary::Hook(_) => "hook",
    ConversationRowSummary::Plan(_) => "plan",
    _ => "other",
  }
}

pub(crate) fn print_session_detail(session: &SessionState) {
  let bold = console::Style::new().bold();
  let project = project_label(session.project_name.as_deref(), &session.project_path);
  println!("{}", bold.apply_to("Session:"));
  println!("  ID:       {}", session.id);
  println!("  Project:  {}", project);
  println!("  Path:     {}", session.project_path);
  println!("  Status:   {}", session_status_str(&session.status));
  println!("  Work:     {}", work_status_str(&session.work_status));
  println!(
    "  Mode:     {} / {}",
    control_mode_str(&session.control_mode),
    lifecycle_state_str(&session.lifecycle_state)
  );
  println!("  Provider: {}", provider_str(&session.provider));
  if let Some(model) = &session.model {
    println!("  Model:    {}", model);
  }
  if let Some(title) = session.custom_name.as_deref() {
    println!("  Name:     {}", title);
  }
  if let Some(summary) = session.summary.as_deref() {
    println!("  Summary:  {}", summary);
  }
  if let Some(prompt) = session.first_prompt.as_deref() {
    println!("  Prompt:   {}", prompt);
  }
  if let Some(branch) = session.git_branch.as_deref() {
    println!("  Branch:   {}", branch);
  }
  if let Some(sha) = session.git_sha.as_deref() {
    println!("  SHA:      {}", sha);
  }
  if let Some(repo) = session.repository_root.as_deref() {
    println!("  Repo:     {}", repo);
  }
  if let Some(approval) = session.approval_policy.as_deref() {
    println!("  Approval: {}", approval);
  }
  if let Some(permission) = session.permission_mode.as_deref() {
    println!("  Permission: {}", permission);
  }
  if let Some(effort) = session.effort.as_deref() {
    println!("  Effort:   {}", effort);
  }
  println!(
    "  Tokens:   {} in / {} out / {} cached",
    session.token_usage.input_tokens,
    session.token_usage.output_tokens,
    session.token_usage.cached_tokens
  );
  println!("  Unread:   {}", session.unread_count);
}

pub(crate) fn print_conversation_snapshot_rows(
  snapshot: &ConversationSnapshotPage,
  seen_row_ids: &mut HashSet<String>,
) {
  for entry in &snapshot.rows {
    if !seen_row_ids.insert(entry.id().to_string()) {
      continue;
    }
    let role = format_row_type_summary(&entry.row);
    let content = truncate(&extract_row_content_str_summary(&entry.row), 120);
    if !content.is_empty() {
      println!("[{role}] {content}");
    }
  }
}

pub(crate) fn print_conversation_snapshot(snapshot: Option<&ConversationSnapshotPage>) {
  let bold = console::Style::new().bold();
  let dim = console::Style::new().dim();

  println!();
  println!("{}", bold.apply_to("Conversation:"));

  let Some(snapshot) = snapshot else {
    println!("No conversation rows yet.");
    return;
  };

  let mut seen_row_ids = HashSet::new();
  print_conversation_snapshot_rows(snapshot, &mut seen_row_ids);

  if snapshot.rows.is_empty() {
    println!("No conversation rows yet.");
  } else if snapshot.has_more_before {
    println!();
    println!(
      "{} showing latest {} of {} rows",
      dim.apply_to("note"),
      snapshot.rows.len(),
      snapshot.total_row_count
    );
  }
}
