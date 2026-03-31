use std::collections::HashSet;
use std::time::Duration;

use base64::Engine;
use orbitdock_protocol::{
  conversation_contracts::extract_row_content_str_summary, ClientMessage, ConversationSnapshotPage,
  DashboardSnapshot, Provider, ServerMessage, SessionDetailSnapshot, SessionListItem, SessionState,
  SessionStatus, SessionSummary, SessionSurface, ToolApprovalDecision, WorkStatus,
};
use serde::{Deserialize, Serialize};

use crate::cli::{
  resolve_stdin, ApprovalDecision, Effort, PermissionMode, ProviderFilter, SessionAction,
  StatusFilter,
};
use crate::client::config::ClientConfig;
use crate::client::rest::RestClient;
use crate::client::ws::WsClient;
use crate::error::{
  CliError, EXIT_CLIENT_ERROR, EXIT_CONNECTION_ERROR, EXIT_SERVER_ERROR, EXIT_SUCCESS,
};
use crate::output::{human, relative_time_label, truncate, Output};

#[derive(Debug, Deserialize, Serialize)]
struct SessionsResponse {
  sessions: Vec<orbitdock_protocol::SessionListItem>,
}

#[derive(Debug, Deserialize, Serialize)]
struct CreateSessionRequest {
  session_id: Option<String>,
  provider: Provider,
  cwd: String,
  model: Option<String>,
  approval_policy: Option<String>,
  approval_policy_details: Option<orbitdock_protocol::CodexApprovalPolicy>,
  sandbox_mode: Option<String>,
  permission_mode: Option<String>,
  allowed_tools: Vec<String>,
  disallowed_tools: Vec<String>,
  effort: Option<String>,
  collaboration_mode: Option<String>,
  multi_agent: Option<bool>,
  personality: Option<String>,
  service_tier: Option<String>,
  developer_instructions: Option<String>,
  system_prompt: Option<String>,
  append_system_prompt: Option<String>,
  allow_bypass_permissions: bool,
  codex_config_mode: Option<orbitdock_protocol::CodexConfigMode>,
  codex_config_profile: Option<String>,
  codex_model_provider: Option<String>,
  codex_config_source: Option<orbitdock_protocol::CodexConfigSource>,
  mission_id: Option<String>,
  issue_id: Option<String>,
  issue_identifier: Option<String>,
  workspace_id: Option<String>,
  initial_prompt: Option<String>,
  skills: Vec<String>,
  tracker_kind: Option<String>,
  tracker_api_key: Option<String>,
}

#[derive(Debug, Deserialize, Serialize)]
struct CreateSessionResponse {
  session_id: String,
  session: SessionSummary,
}

#[derive(Debug, Deserialize, Serialize)]
struct ResumeSessionResponse {
  session_id: String,
  session: SessionSummary,
}

#[derive(Debug, Deserialize, Serialize)]
struct ForkSessionRequest {
  nth_user_message: Option<u32>,
  model: Option<String>,
  approval_policy: Option<String>,
  sandbox_mode: Option<String>,
  cwd: Option<String>,
  permission_mode: Option<String>,
  allowed_tools: Vec<String>,
  disallowed_tools: Vec<String>,
}

#[derive(Debug, Deserialize, Serialize)]
struct ForkSessionResponse {
  source_session_id: String,
  new_session_id: String,
  session: SessionSummary,
}

#[derive(Debug, Serialize)]
struct SessionJsonOverview {
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
struct SessionListJsonResponse {
  kind: &'static str,
  count: usize,
  sessions: Vec<SessionListItem>,
  summaries: Vec<SessionJsonOverview>,
}

#[derive(Debug, Serialize)]
struct SessionConversationJsonSummary {
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
struct SessionDetailJsonResponse {
  kind: &'static str,
  revision: u64,
  session: SessionState,
  summary: SessionJsonOverview,
  conversation: SessionConversationJsonSummary,
}

#[derive(Debug, Serialize)]
struct SessionActionJsonResponse {
  ok: bool,
  action: &'static str,
  session_id: String,
  #[serde(skip_serializing_if = "Option::is_none")]
  source_session_id: Option<String>,
  session: SessionSummary,
  summary: SessionJsonOverview,
}

pub async fn run(
  action: &SessionAction,
  rest: &RestClient,
  output: &Output,
  config: &ClientConfig,
) -> i32 {
  match action {
    // REST commands
    SessionAction::List {
      provider,
      status,
      project,
    } => {
      list(
        rest,
        output,
        provider.as_ref(),
        status.as_ref(),
        project.as_deref(),
      )
      .await
    }
    SessionAction::Get {
      session_id,
      messages,
    } => get(rest, output, session_id, *messages).await,

    // WS commands
    SessionAction::Create {
      provider,
      cwd,
      model,
      permission_mode,
      effort,
      system_prompt,
    } => {
      let resolved_cwd = match cwd {
        Some(c) => c.clone(),
        None => std::env::current_dir()
          .map(|p| p.to_string_lossy().to_string())
          .unwrap_or_else(|_| ".".to_string()),
      };
      create(CreateSessionArgs {
        rest,
        output,
        provider_filter: provider,
        cwd: &resolved_cwd,
        model: model.as_deref(),
        permission_mode: permission_mode.as_ref(),
        effort: effort.as_ref(),
        system_prompt: system_prompt.as_deref(),
      })
      .await
    }
    SessionAction::Send {
      session_id,
      content,
      model,
      effort,
      no_wait,
    } => {
      let resolved = match resolve_stdin(content) {
        Ok(c) => c,
        Err(e) => {
          output.print_error(&CliError::new("stdin_error", e.to_string()));
          return EXIT_CLIENT_ERROR;
        }
      };
      send_message(
        config,
        output,
        session_id,
        &resolved,
        model.as_deref(),
        effort.as_ref(),
        *no_wait,
      )
      .await
    }
    SessionAction::Approve {
      session_id,
      decision,
      message,
      request_id,
    } => {
      approve_tool(
        config,
        output,
        session_id,
        decision,
        message.as_deref(),
        request_id.as_deref(),
      )
      .await
    }
    SessionAction::Answer {
      session_id,
      answer,
      request_id,
    } => {
      let resolved = match resolve_stdin(answer) {
        Ok(a) => a,
        Err(e) => {
          output.print_error(&CliError::new("stdin_error", e.to_string()));
          return EXIT_CLIENT_ERROR;
        }
      };
      answer_question(config, output, session_id, &resolved, request_id.as_deref()).await
    }
    SessionAction::Interrupt { session_id } => interrupt(config, output, session_id).await,
    SessionAction::End { session_id } => end_session(config, output, session_id).await,
    SessionAction::Fork {
      session_id,
      nth_user_message,
      model,
    } => {
      fork(
        rest,
        output,
        session_id,
        *nth_user_message,
        model.as_deref(),
      )
      .await
    }
    SessionAction::Steer {
      session_id,
      content,
    } => {
      let resolved = match resolve_stdin(content) {
        Ok(c) => c,
        Err(e) => {
          output.print_error(&CliError::new("stdin_error", e.to_string()));
          return EXIT_CLIENT_ERROR;
        }
      };
      steer(config, output, session_id, &resolved).await
    }
    SessionAction::Compact { session_id } => compact(config, output, session_id).await,
    SessionAction::Undo { session_id } => undo(config, output, session_id).await,
    SessionAction::Rollback { session_id, turns } => {
      rollback(config, output, session_id, *turns).await
    }
    SessionAction::Watch {
      session_id,
      filter,
      timeout,
    } => watch(rest, config, output, session_id, filter, *timeout).await,
    SessionAction::Rename { session_id, name } => rename(config, output, session_id, name).await,
    SessionAction::Resume { session_id } => resume(rest, output, session_id).await,
  }
}

// ── Helpers ──────────────────────────────────────────────────

async fn ws_connect(config: &ClientConfig, output: &Output) -> Option<WsClient> {
  match WsClient::connect(config).await {
    Ok(ws) => Some(ws),
    Err(e) => {
      output.print_error(&CliError::connection(e.to_string()));
      None
    }
  }
}

async fn fetch_session_detail_snapshot(
  config: &ClientConfig,
  session_id: &str,
) -> Result<SessionDetailSnapshot, CliError> {
  let rest = RestClient::new(config);
  rest
    .get::<SessionDetailSnapshot>(&format!("/api/sessions/{session_id}/detail"))
    .await
    .into_result()
    .map_err(|(_, err)| err)
}

async fn fetch_conversation_snapshot(
  config: &ClientConfig,
  session_id: &str,
  limit: usize,
) -> Result<ConversationSnapshotPage, CliError> {
  let rest = RestClient::new(config);
  rest
    .get::<ConversationSnapshotPage>(&format!(
      "/api/sessions/{session_id}/conversation?limit={limit}"
    ))
    .await
    .into_result()
    .map_err(|(_, err)| err)
}

async fn subscribe_session_surface(
  ws: &mut WsClient,
  session_id: &str,
  surface: SessionSurface,
  since_revision: Option<u64>,
) -> Result<(), CliError> {
  ws.send(&ClientMessage::SubscribeSessionSurface {
    session_id: session_id.to_string(),
    surface,
    since_revision,
  })
  .await
  .map_err(|error| CliError::connection(error.to_string()))
}

async fn bootstrap_session_subscription(
  config: &ClientConfig,
  ws: &mut WsClient,
  session_id: &str,
) -> Result<SessionState, CliError> {
  let snapshot = fetch_session_detail_snapshot(config, session_id).await?;
  subscribe_session_surface(
    ws,
    session_id,
    SessionSurface::Detail,
    Some(snapshot.revision),
  )
  .await?;
  Ok(snapshot.session)
}

fn pending_request_id(session: &SessionState) -> Option<&str> {
  session.pending_approval.as_ref().map(|req| req.id.as_str())
}

fn provider_str(p: &Provider) -> &'static str {
  match p {
    Provider::Claude => "claude",
    Provider::Codex => "codex",
  }
}

fn project_label(project_name: Option<&str>, project_path: &str) -> String {
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

fn session_status_str(s: &SessionStatus) -> &'static str {
  match s {
    SessionStatus::Active => "active",
    SessionStatus::Ended => "ended",
  }
}

fn work_status_str(s: &WorkStatus) -> &'static str {
  match s {
    WorkStatus::Working => "working",
    WorkStatus::Waiting => "waiting",
    WorkStatus::Permission => "permission",
    WorkStatus::Question => "question",
    WorkStatus::Reply => "reply",
    WorkStatus::Ended => "ended",
  }
}

fn list_status_str(s: &orbitdock_protocol::SessionListStatus) -> &'static str {
  match s {
    orbitdock_protocol::SessionListStatus::Working => "working",
    orbitdock_protocol::SessionListStatus::Permission => "permission",
    orbitdock_protocol::SessionListStatus::Question => "question",
    orbitdock_protocol::SessionListStatus::Reply => "reply",
    orbitdock_protocol::SessionListStatus::Ended => "ended",
  }
}

fn control_mode_str(s: &orbitdock_protocol::SessionControlMode) -> &'static str {
  match s {
    orbitdock_protocol::SessionControlMode::Direct => "direct",
    orbitdock_protocol::SessionControlMode::Passive => "passive",
  }
}

fn lifecycle_state_str(s: &orbitdock_protocol::SessionLifecycleState) -> &'static str {
  match s {
    orbitdock_protocol::SessionLifecycleState::Open => "open",
    orbitdock_protocol::SessionLifecycleState::Resumable => "resumable",
    orbitdock_protocol::SessionLifecycleState::Ended => "ended",
  }
}

fn token_usage_snapshot_kind_str(kind: orbitdock_protocol::TokenUsageSnapshotKind) -> &'static str {
  match kind {
    orbitdock_protocol::TokenUsageSnapshotKind::Unknown => "unknown",
    orbitdock_protocol::TokenUsageSnapshotKind::ContextTurn => "context_turn",
    orbitdock_protocol::TokenUsageSnapshotKind::LifetimeTotals => "lifetime_totals",
    orbitdock_protocol::TokenUsageSnapshotKind::MixedLegacy => "mixed_legacy",
    orbitdock_protocol::TokenUsageSnapshotKind::CompactionReset => "compaction_reset",
  }
}

fn detail_preview(value: &str) -> String {
  let flattened = value.split_whitespace().collect::<Vec<_>>().join(" ");
  truncate(&flattened, 160)
}

fn compact_context_line(value: Option<&str>) -> Option<String> {
  value.map(detail_preview)
}

fn trusted_cache_hit_percent(input_tokens: u64, cached_tokens: u64) -> Option<f64> {
  if input_tokens == 0 || cached_tokens > input_tokens {
    return None;
  }
  Some((cached_tokens as f64 / input_tokens as f64) * 100.0)
}

fn session_json_overview_from_list_item(session: &SessionListItem) -> SessionJsonOverview {
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
    // Session list rows do not carry enough token context to derive a stable cache ratio.
    cache_hit_percent: None,
    unread_count: session.unread_count,
  }
}

fn session_json_overview_from_summary(session: &SessionSummary) -> SessionJsonOverview {
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

fn session_json_overview_from_state(session: &SessionState) -> SessionJsonOverview {
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

fn build_session_list_json_response(sessions: Vec<SessionListItem>) -> SessionListJsonResponse {
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

fn build_session_detail_json_response(
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

fn conversation_snapshot_from_session(session: &SessionState) -> Option<ConversationSnapshotPage> {
  if session.rows.is_empty() {
    return None;
  }

  Some(ConversationSnapshotPage {
    revision: session.revision.unwrap_or_default(),
    session_id: session.id.clone(),
    session: session.clone(),
    rows: session.rows.iter().map(|row| row.to_summary()).collect(),
    total_row_count: session.total_row_count,
    has_more_before: session.has_more_before,
    oldest_sequence: session.oldest_sequence,
    newest_sequence: session.newest_sequence,
  })
}

fn stream_turn_should_exit(status: &WorkStatus, saw_turn_activity: bool) -> bool {
  match status {
    WorkStatus::Working => false,
    WorkStatus::Waiting => saw_turn_activity,
    _ => true,
  }
}

// ── REST Commands ────────────────────────────────────────────

async fn list(
  rest: &RestClient,
  output: &Output,
  provider: Option<&ProviderFilter>,
  status: Option<&StatusFilter>,
  project: Option<&str>,
) -> i32 {
  match rest
    .get::<DashboardSnapshot>("/api/dashboard")
    .await
    .into_result()
  {
    Ok(snapshot) => {
      let mut resp = SessionsResponse {
        sessions: snapshot.sessions,
      };
      if let Some(p) = provider {
        let target = match p {
          ProviderFilter::Claude => Provider::Claude,
          ProviderFilter::Codex => Provider::Codex,
        };
        resp.sessions.retain(|s| s.provider == target);
      }
      if let Some(s) = status {
        let target = match s {
          StatusFilter::Active => orbitdock_protocol::SessionStatus::Active,
          StatusFilter::Ended => orbitdock_protocol::SessionStatus::Ended,
        };
        resp.sessions.retain(|s| s.status == target);
      }
      if let Some(proj) = project {
        resp.sessions.retain(|s| s.project_path.contains(proj));
      }

      if output.json {
        output.print_json_pretty(&build_session_list_json_response(resp.sessions));
      } else {
        human::sessions_table(&resp.sessions);
      }
      EXIT_SUCCESS
    }
    Err((code, err)) => {
      output.print_error(&err);
      code
    }
  }
}

async fn get(rest: &RestClient, output: &Output, session_id: &str, messages: bool) -> i32 {
  let path = if messages {
    format!("/api/sessions/{session_id}/detail?include_messages=true")
  } else {
    format!("/api/sessions/{session_id}/detail")
  };
  match rest.get::<SessionDetailSnapshot>(&path).await.into_result() {
    Ok(snapshot) => {
      if output.json {
        output.print_json_pretty(&build_session_detail_json_response(snapshot, messages));
      } else {
        let conversation = if messages {
          if let Some(snapshot_page) = conversation_snapshot_from_session(&snapshot.session) {
            Some(snapshot_page)
          } else if snapshot.session.total_row_count == 0 {
            None
          } else {
            let limit = snapshot.session.total_row_count.min(200) as usize;
            match rest
              .get::<ConversationSnapshotPage>(&format!(
                "/api/sessions/{session_id}/conversation?limit={limit}"
              ))
              .await
              .into_result()
            {
              Ok(snapshot) => Some(snapshot),
              Err((code, err)) => {
                output.print_error(&err);
                return code;
              }
            }
          }
        } else {
          None
        };

        print_session_detail(&snapshot.session);
        if messages {
          print_conversation_snapshot(conversation.as_ref());
        }
      }
      EXIT_SUCCESS
    }
    Err((code, err)) => {
      output.print_error(&err);
      code
    }
  }
}

// ── WS Commands ──────────────────────────────────────────────

struct CreateSessionArgs<'a> {
  rest: &'a RestClient,
  output: &'a Output,
  provider_filter: &'a ProviderFilter,
  cwd: &'a str,
  model: Option<&'a str>,
  permission_mode: Option<&'a PermissionMode>,
  effort: Option<&'a Effort>,
  system_prompt: Option<&'a str>,
}

async fn create(args: CreateSessionArgs<'_>) -> i32 {
  let CreateSessionArgs {
    rest,
    output,
    provider_filter,
    cwd,
    model,
    permission_mode,
    effort,
    system_prompt,
  } = args;

  let provider = match provider_filter {
    ProviderFilter::Claude => Provider::Claude,
    ProviderFilter::Codex => Provider::Codex,
  };

  let request = CreateSessionRequest {
    provider,
    cwd: cwd.to_string(),
    model: model.map(str::to_string),
    approval_policy: None,
    approval_policy_details: None,
    sandbox_mode: None,
    permission_mode: permission_mode.map(|m| m.as_str().to_string()),
    allowed_tools: vec![],
    disallowed_tools: vec![],
    effort: effort.map(|e| e.as_str().to_string()),
    collaboration_mode: None,
    multi_agent: None,
    personality: None,
    service_tier: None,
    developer_instructions: None,
    system_prompt: system_prompt.map(str::to_string),
    append_system_prompt: None,
    allow_bypass_permissions: false,
    codex_config_mode: None,
    codex_config_profile: None,
    codex_model_provider: None,
    codex_config_source: None,
    session_id: None,
    mission_id: None,
    issue_id: None,
    issue_identifier: None,
    workspace_id: None,
    initial_prompt: None,
    skills: vec![],
    tracker_kind: None,
    tracker_api_key: None,
  };

  match rest
    .post_json::<_, CreateSessionResponse>("/api/sessions", &request)
    .await
    .into_result()
  {
    Ok(resp) => {
      let session = resp.session;
      if output.json {
        output.print_json_pretty(&SessionActionJsonResponse {
          ok: true,
          action: "created",
          session_id: session.id.clone(),
          source_session_id: None,
          summary: session_json_overview_from_summary(&session),
          session,
        });
      } else {
        let bold = console::Style::new().bold();
        println!("{} {}", bold.apply_to("Created session:"), session.id);
        println!(
          "{} {}",
          bold.apply_to("Provider:"),
          provider_str(&session.provider)
        );
        println!("{} {}", bold.apply_to("Project:"), session.project_path);
      }
      EXIT_SUCCESS
    }
    Err((code, err)) => {
      output.print_error(&err);
      code
    }
  }
}

pub fn run_managed_session_start(
  server_url: Option<&str>,
  request_base64: &str,
) -> anyhow::Result<()> {
  let request_bytes = base64::engine::general_purpose::STANDARD
    .decode(request_base64)
    .map_err(|error| anyhow::anyhow!("decode managed session request: {error}"))?;
  let request: CreateSessionRequest = serde_json::from_slice(&request_bytes)
    .map_err(|error| anyhow::anyhow!("parse managed session request: {error}"))?;

  let config = ClientConfig::from_sources(server_url, None, true, None);
  let rest = RestClient::new(&config);
  let runtime = tokio::runtime::Builder::new_current_thread()
    .enable_all()
    .build()
    .map_err(|error| anyhow::anyhow!("build Tokio runtime: {error}"))?;

  let result = runtime.block_on(async move {
    rest
      .post_json::<_, CreateSessionResponse>("/api/sessions", &request)
      .await
      .into_result()
  });

  match result {
    Ok(_) => Ok(()),
    Err((code, error)) => Err(anyhow::anyhow!(
      "managed session start failed (exit {code}): {}",
      error.message
    )),
  }
}

async fn send_message(
  config: &ClientConfig,
  output: &Output,
  session_id: &str,
  content: &str,
  model: Option<&str>,
  effort: Option<&Effort>,
  no_wait: bool,
) -> i32 {
  let Some(mut ws) = ws_connect(config, output).await else {
    return EXIT_CONNECTION_ERROR;
  };

  if let Err(err) = bootstrap_session_subscription(config, &mut ws, session_id).await {
    output.print_error(&err);
    return EXIT_SERVER_ERROR;
  }

  let conversation_revision = match fetch_conversation_snapshot(config, session_id, 50).await {
    Ok(snapshot) => snapshot.revision,
    Err(err) => {
      output.print_error(&err);
      return EXIT_SERVER_ERROR;
    }
  };

  if let Err(err) = subscribe_session_surface(
    &mut ws,
    session_id,
    SessionSurface::Conversation,
    Some(conversation_revision),
  )
  .await
  {
    output.print_error(&err);
    return EXIT_CONNECTION_ERROR;
  }

  if let Err(e) = ws
    .send(&ClientMessage::SendMessage {
      session_id: session_id.to_string(),
      content: content.to_string(),
      model: model.map(str::to_string),
      effort: effort.map(|e| e.as_str().to_string()),
      skills: vec![],
      images: vec![],
      mentions: vec![],
    })
    .await
  {
    output.print_error(&CliError::connection(e.to_string()));
    return EXIT_CONNECTION_ERROR;
  }

  if no_wait {
    if output.json {
      output.print_json(&serde_json::json!({"sent": true, "session_id": session_id}));
    } else {
      println!("Message sent.");
    }
    return EXIT_SUCCESS;
  }

  stream_turn_events(&mut ws, output).await
}

async fn approve_tool(
  config: &ClientConfig,
  output: &Output,
  session_id: &str,
  decision: &ApprovalDecision,
  message: Option<&str>,
  request_id: Option<&str>,
) -> i32 {
  let Some(mut ws) = ws_connect(config, output).await else {
    return EXIT_CONNECTION_ERROR;
  };

  if let Err(err) = bootstrap_session_subscription(config, &mut ws, session_id).await {
    output.print_error(&err);
    return EXIT_SERVER_ERROR;
  }

  let session = match bootstrap_session_subscription(config, &mut ws, session_id).await {
    Ok(session) => session,
    Err(err) => {
      output.print_error(&err);
      return EXIT_SERVER_ERROR;
    }
  };

  let resolved_id = match request_id {
    Some(id) => id.to_string(),
    None => match pending_request_id(&session) {
      Some(id) => id.to_string(),
      None => {
        output.print_error(&CliError::new(
          "no_pending_approval",
          "No pending approval. Use --request-id to specify one.",
        ));
        return EXIT_CLIENT_ERROR;
      }
    },
  };

  if let Err(e) = ws
    .send(&ClientMessage::ApproveTool {
      session_id: session_id.to_string(),
      request_id: resolved_id.clone(),
      decision: match decision {
        ApprovalDecision::Approved => ToolApprovalDecision::Approved,
        ApprovalDecision::ApprovedForSession => ToolApprovalDecision::ApprovedForSession,
        ApprovalDecision::ApprovedAlways => ToolApprovalDecision::ApprovedAlways,
        ApprovalDecision::Denied => ToolApprovalDecision::Denied,
        ApprovalDecision::Abort => ToolApprovalDecision::Abort,
      },
      message: message.map(str::to_string),
      interrupt: None,
      updated_input: None,
    })
    .await
  {
    output.print_error(&CliError::connection(e.to_string()));
    return EXIT_CONNECTION_ERROR;
  }

  loop {
    match ws.recv_timeout(Duration::from_secs(10)).await {
      Ok(Some(ServerMessage::ApprovalDecisionResult {
        ref request_id,
        ref outcome,
        ..
      }))
        if *request_id == resolved_id =>
      {
        if output.json {
          output.print_json(&serde_json::json!({
              "request_id": request_id,
              "outcome": outcome,
          }));
        } else {
          let bold = console::Style::new().bold();
          println!(
            "{} {} ({})",
            bold.apply_to("Approval:"),
            outcome,
            request_id
          );
        }
        return EXIT_SUCCESS;
      }
      Ok(Some(ServerMessage::Error { code, message, .. })) => {
        output.print_error(&CliError::new(code, message));
        return EXIT_SERVER_ERROR;
      }
      Ok(Some(_)) => continue,
      Ok(None) => {
        output.print_error(&CliError::connection(
          "Timed out waiting for approval result",
        ));
        return EXIT_CONNECTION_ERROR;
      }
      Err(e) => {
        output.print_error(&CliError::connection(e.to_string()));
        return EXIT_CONNECTION_ERROR;
      }
    }
  }
}

async fn answer_question(
  config: &ClientConfig,
  output: &Output,
  session_id: &str,
  answer: &str,
  request_id: Option<&str>,
) -> i32 {
  let Some(mut ws) = ws_connect(config, output).await else {
    return EXIT_CONNECTION_ERROR;
  };

  if let Err(err) = bootstrap_session_subscription(config, &mut ws, session_id).await {
    output.print_error(&err);
    return EXIT_SERVER_ERROR;
  }

  let session = match bootstrap_session_subscription(config, &mut ws, session_id).await {
    Ok(session) => session,
    Err(err) => {
      output.print_error(&err);
      return EXIT_SERVER_ERROR;
    }
  };

  let resolved_id = match request_id {
    Some(id) => id.to_string(),
    None => match pending_request_id(&session) {
      Some(id) => id.to_string(),
      None => {
        output.print_error(&CliError::new(
          "no_pending_question",
          "No pending question. Use --request-id to specify one.",
        ));
        return EXIT_CLIENT_ERROR;
      }
    },
  };

  if let Err(e) = ws
    .send(&ClientMessage::AnswerQuestion {
      session_id: session_id.to_string(),
      request_id: resolved_id.clone(),
      answer: answer.to_string(),
      question_id: None,
      answers: None,
    })
    .await
  {
    output.print_error(&CliError::connection(e.to_string()));
    return EXIT_CONNECTION_ERROR;
  }

  loop {
    match ws.recv_timeout(Duration::from_secs(10)).await {
      Ok(Some(ServerMessage::ApprovalDecisionResult {
        ref request_id,
        ref outcome,
        ..
      }))
        if *request_id == resolved_id =>
      {
        if output.json {
          output.print_json(&serde_json::json!({
              "request_id": request_id,
              "outcome": outcome,
          }));
        } else {
          println!("Answer submitted ({outcome})");
        }
        return EXIT_SUCCESS;
      }
      Ok(Some(ServerMessage::Error { code, message, .. })) => {
        output.print_error(&CliError::new(code, message));
        return EXIT_SERVER_ERROR;
      }
      Ok(Some(_)) => continue,
      Ok(None) => {
        output.print_error(&CliError::connection("Timed out"));
        return EXIT_CONNECTION_ERROR;
      }
      Err(e) => {
        output.print_error(&CliError::connection(e.to_string()));
        return EXIT_CONNECTION_ERROR;
      }
    }
  }
}

async fn interrupt(config: &ClientConfig, output: &Output, session_id: &str) -> i32 {
  let Some(mut ws) = ws_connect(config, output).await else {
    return EXIT_CONNECTION_ERROR;
  };

  if let Err(err) = bootstrap_session_subscription(config, &mut ws, session_id).await {
    output.print_error(&err);
    return EXIT_SERVER_ERROR;
  }

  if let Err(e) = ws
    .send(&ClientMessage::InterruptSession {
      session_id: session_id.to_string(),
    })
    .await
  {
    output.print_error(&CliError::connection(e.to_string()));
    return EXIT_CONNECTION_ERROR;
  }

  loop {
    match ws.recv_timeout(Duration::from_secs(5)).await {
      Ok(Some(ServerMessage::SessionDelta { changes, .. })) => {
        if let Some(status) = changes.work_status.as_ref() {
          if *status != WorkStatus::Working {
            if output.json {
              output.print_json(
                &serde_json::json!({"interrupted": true, "work_status": work_status_str(status)}),
              );
            } else {
              println!("Session interrupted. Status: {}", work_status_str(status));
            }
            return EXIT_SUCCESS;
          }
        }
      }
      Ok(Some(ServerMessage::Error { code, message, .. })) => {
        output.print_error(&CliError::new(code, message));
        return EXIT_SERVER_ERROR;
      }
      Ok(Some(_)) => continue,
      Ok(None) => {
        if output.json {
          output.print_json(&serde_json::json!({"interrupted": true}));
        } else {
          println!("Interrupt sent.");
        }
        return EXIT_SUCCESS;
      }
      Err(e) => {
        output.print_error(&CliError::connection(e.to_string()));
        return EXIT_CONNECTION_ERROR;
      }
    }
  }
}

async fn end_session(config: &ClientConfig, output: &Output, session_id: &str) -> i32 {
  let Some(mut ws) = ws_connect(config, output).await else {
    return EXIT_CONNECTION_ERROR;
  };

  if let Err(err) = bootstrap_session_subscription(config, &mut ws, session_id).await {
    output.print_error(&err);
    return EXIT_SERVER_ERROR;
  }

  if let Err(e) = ws
    .send(&ClientMessage::EndSession {
      session_id: session_id.to_string(),
    })
    .await
  {
    output.print_error(&CliError::connection(e.to_string()));
    return EXIT_CONNECTION_ERROR;
  }

  loop {
    match ws.recv_timeout(Duration::from_secs(10)).await {
      Ok(Some(ServerMessage::SessionEnded { reason, .. })) => {
        if output.json {
          output.print_json(&serde_json::json!({"ended": true, "reason": reason}));
        } else {
          println!("Session ended: {reason}");
        }
        return EXIT_SUCCESS;
      }
      Ok(Some(ServerMessage::Error { code, message, .. })) => {
        output.print_error(&CliError::new(code, message));
        return EXIT_SERVER_ERROR;
      }
      Ok(Some(_)) => continue,
      Ok(None) => {
        if output.json {
          output.print_json(&serde_json::json!({"ended": true}));
        } else {
          println!("End request sent.");
        }
        return EXIT_SUCCESS;
      }
      Err(e) => {
        output.print_error(&CliError::connection(e.to_string()));
        return EXIT_CONNECTION_ERROR;
      }
    }
  }
}

async fn fork(
  rest: &RestClient,
  output: &Output,
  session_id: &str,
  nth_user_message: Option<u32>,
  model: Option<&str>,
) -> i32 {
  let request = ForkSessionRequest {
    nth_user_message,
    model: model.map(str::to_string),
    approval_policy: None,
    sandbox_mode: None,
    cwd: None,
    permission_mode: None,
    allowed_tools: vec![],
    disallowed_tools: vec![],
  };

  match rest
    .post_json::<_, ForkSessionResponse>(&format!("/api/sessions/{session_id}/fork"), &request)
    .await
    .into_result()
  {
    Ok(resp) => {
      let session = resp.session;
      if output.json {
        output.print_json_pretty(&SessionActionJsonResponse {
          ok: true,
          action: "forked",
          session_id: resp.new_session_id,
          source_session_id: Some(resp.source_session_id),
          summary: session_json_overview_from_summary(&session),
          session,
        });
      } else {
        let bold = console::Style::new().bold();
        println!(
          "{} {} (from {})",
          bold.apply_to("Forked:"),
          resp.new_session_id,
          resp.source_session_id
        );
      }
      EXIT_SUCCESS
    }
    Err((code, err)) => {
      output.print_error(&err);
      code
    }
  }
}

async fn steer(config: &ClientConfig, output: &Output, session_id: &str, content: &str) -> i32 {
  let Some(mut ws) = ws_connect(config, output).await else {
    return EXIT_CONNECTION_ERROR;
  };

  if let Err(err) = bootstrap_session_subscription(config, &mut ws, session_id).await {
    output.print_error(&err);
    return EXIT_SERVER_ERROR;
  }

  if let Err(e) = ws
    .send(&ClientMessage::SteerTurn {
      session_id: session_id.to_string(),
      content: content.to_string(),
      images: vec![],
      mentions: vec![],
    })
    .await
  {
    output.print_error(&CliError::connection(e.to_string()));
    return EXIT_CONNECTION_ERROR;
  }

  if output.json {
    output.print_json(&serde_json::json!({"steered": true, "session_id": session_id}));
  } else {
    println!("Guidance injected.");
  }
  EXIT_SUCCESS
}

async fn compact(config: &ClientConfig, output: &Output, session_id: &str) -> i32 {
  let Some(mut ws) = ws_connect(config, output).await else {
    return EXIT_CONNECTION_ERROR;
  };

  if let Err(err) = bootstrap_session_subscription(config, &mut ws, session_id).await {
    output.print_error(&err);
    return EXIT_SERVER_ERROR;
  }

  if let Err(e) = ws
    .send(&ClientMessage::CompactContext {
      session_id: session_id.to_string(),
    })
    .await
  {
    output.print_error(&CliError::connection(e.to_string()));
    return EXIT_CONNECTION_ERROR;
  }

  loop {
    match ws.recv_timeout(Duration::from_secs(60)).await {
      Ok(Some(ServerMessage::ContextCompacted { .. })) => {
        if output.json {
          output.print_json(&serde_json::json!({"compacted": true}));
        } else {
          println!("Context compacted.");
        }
        return EXIT_SUCCESS;
      }
      Ok(Some(ServerMessage::Error { code, message, .. })) => {
        output.print_error(&CliError::new(code, message));
        return EXIT_SERVER_ERROR;
      }
      Ok(Some(_)) => continue,
      Ok(None) => {
        output.print_error(&CliError::connection("Timed out waiting for compaction"));
        return EXIT_CONNECTION_ERROR;
      }
      Err(e) => {
        output.print_error(&CliError::connection(e.to_string()));
        return EXIT_CONNECTION_ERROR;
      }
    }
  }
}

async fn undo(config: &ClientConfig, output: &Output, session_id: &str) -> i32 {
  let Some(mut ws) = ws_connect(config, output).await else {
    return EXIT_CONNECTION_ERROR;
  };

  if let Err(err) = bootstrap_session_subscription(config, &mut ws, session_id).await {
    output.print_error(&err);
    return EXIT_SERVER_ERROR;
  }

  if let Err(e) = ws
    .send(&ClientMessage::UndoLastTurn {
      session_id: session_id.to_string(),
    })
    .await
  {
    output.print_error(&CliError::connection(e.to_string()));
    return EXIT_CONNECTION_ERROR;
  }

  loop {
    match ws.recv_timeout(Duration::from_secs(30)).await {
      Ok(Some(ServerMessage::UndoCompleted {
        success, message, ..
      })) => {
        if output.json {
          output.print_json(&serde_json::json!({"undone": success, "message": message}));
        } else if success {
          println!(
            "Undo complete.{}",
            message.map(|m| format!(" {m}")).unwrap_or_default()
          );
        } else {
          eprintln!(
            "Undo failed.{}",
            message.map(|m| format!(" {m}")).unwrap_or_default()
          );
        }
        return if success {
          EXIT_SUCCESS
        } else {
          EXIT_SERVER_ERROR
        };
      }
      Ok(Some(ServerMessage::UndoStarted { .. })) => continue,
      Ok(Some(ServerMessage::Error { code, message, .. })) => {
        output.print_error(&CliError::new(code, message));
        return EXIT_SERVER_ERROR;
      }
      Ok(Some(_)) => continue,
      Ok(None) => {
        output.print_error(&CliError::connection("Timed out waiting for undo"));
        return EXIT_CONNECTION_ERROR;
      }
      Err(e) => {
        output.print_error(&CliError::connection(e.to_string()));
        return EXIT_CONNECTION_ERROR;
      }
    }
  }
}

async fn rollback(config: &ClientConfig, output: &Output, session_id: &str, turns: u32) -> i32 {
  let Some(mut ws) = ws_connect(config, output).await else {
    return EXIT_CONNECTION_ERROR;
  };

  if let Err(err) = bootstrap_session_subscription(config, &mut ws, session_id).await {
    output.print_error(&err);
    return EXIT_SERVER_ERROR;
  }

  if let Err(e) = ws
    .send(&ClientMessage::RollbackTurns {
      session_id: session_id.to_string(),
      num_turns: turns,
    })
    .await
  {
    output.print_error(&CliError::connection(e.to_string()));
    return EXIT_CONNECTION_ERROR;
  }

  loop {
    match ws.recv_timeout(Duration::from_secs(30)).await {
      Ok(Some(ServerMessage::ThreadRolledBack { num_turns, .. })) => {
        if output.json {
          output.print_json(&serde_json::json!({"rolled_back": num_turns}));
        } else {
          println!("Rolled back {num_turns} turn(s).");
        }
        return EXIT_SUCCESS;
      }
      Ok(Some(ServerMessage::Error { code, message, .. })) => {
        output.print_error(&CliError::new(code, message));
        return EXIT_SERVER_ERROR;
      }
      Ok(Some(_)) => continue,
      Ok(None) => {
        output.print_error(&CliError::connection("Timed out"));
        return EXIT_CONNECTION_ERROR;
      }
      Err(e) => {
        output.print_error(&CliError::connection(e.to_string()));
        return EXIT_CONNECTION_ERROR;
      }
    }
  }
}

async fn watch(
  rest: &RestClient,
  config: &ClientConfig,
  output: &Output,
  session_id: &str,
  filter: &[String],
  timeout_secs: Option<u64>,
) -> i32 {
  let detail = match rest
    .get::<SessionDetailSnapshot>(&format!("/api/sessions/{session_id}/detail"))
    .await
    .into_result()
  {
    Ok(snapshot) => snapshot,
    Err((code, err)) => {
      output.print_error(&err);
      return code;
    }
  };
  let conversation = match rest
    .get::<ConversationSnapshotPage>(&format!(
      "/api/sessions/{session_id}/conversation?limit=200"
    ))
    .await
    .into_result()
  {
    Ok(snapshot) => snapshot,
    Err((code, err)) => {
      output.print_error(&err);
      return code;
    }
  };

  let Some(mut ws) = ws_connect(config, output).await else {
    return EXIT_CONNECTION_ERROR;
  };

  if let Err(e) = ws
    .subscribe_session_surface(session_id, SessionSurface::Detail, Some(detail.revision))
    .await
  {
    output.print_error(&CliError::connection(e.to_string()));
    return EXIT_CONNECTION_ERROR;
  }
  if let Err(e) = ws
    .subscribe_session_surface(
      session_id,
      SessionSurface::Conversation,
      Some(conversation.revision),
    )
    .await
  {
    output.print_error(&CliError::connection(e.to_string()));
    return EXIT_CONNECTION_ERROR;
  }

  if output.json {
    output.print_json(&serde_json::json!({
        "type": "bootstrap_detail",
        "snapshot": detail,
    }));
    output.print_json(&serde_json::json!({
        "type": "bootstrap_conversation",
        "snapshot": conversation,
    }));
  } else {
    let bold = console::Style::new().bold();
    println!(
      "{} {} ({} / {})",
      bold.apply_to("Watching:"),
      session_id,
      provider_str(&detail.session.provider),
      work_status_str(&detail.session.work_status)
    );
    let mut seen_row_ids = HashSet::new();
    print_conversation_snapshot_rows(&conversation, &mut seen_row_ids);
    println!("Press Ctrl+C to stop.\n");
  }

  // Default: no timeout (wait indefinitely until session ends or Ctrl+C)
  let timeout = timeout_secs
    .map(Duration::from_secs)
    .unwrap_or(Duration::from_secs(u64::MAX / 2));

  loop {
    match ws.recv_timeout(timeout).await {
      Ok(Some(ref msg)) => {
        if !filter.is_empty() {
          let event_type = event_type_name(msg);
          if !filter.iter().any(|f| event_type.contains(f.as_str())) {
            continue;
          }
        }

        if output.json {
          output.print_json(msg);
        } else {
          print_watch_event(msg);
        }

        if matches!(msg, ServerMessage::SessionEnded { .. }) {
          return EXIT_SUCCESS;
        }
      }
      Ok(None) => {
        if !output.json {
          println!("\nConnection closed.");
        }
        return EXIT_SUCCESS;
      }
      Err(e) => {
        output.print_error(&CliError::connection(e.to_string()));
        return EXIT_CONNECTION_ERROR;
      }
    }
  }
}

async fn rename(config: &ClientConfig, output: &Output, session_id: &str, name: &str) -> i32 {
  let Some(mut ws) = ws_connect(config, output).await else {
    return EXIT_CONNECTION_ERROR;
  };

  if let Err(e) = ws
    .send(&ClientMessage::RenameSession {
      session_id: session_id.to_string(),
      name: Some(name.to_string()),
    })
    .await
  {
    output.print_error(&CliError::connection(e.to_string()));
    return EXIT_CONNECTION_ERROR;
  }

  match ws.recv_timeout(Duration::from_secs(5)).await {
    Ok(Some(ServerMessage::Error { code, message, .. })) => {
      output.print_error(&CliError::new(code, message));
      return EXIT_SERVER_ERROR;
    }
    Err(e) => {
      output.print_error(&CliError::connection(e.to_string()));
      return EXIT_CONNECTION_ERROR;
    }
    _ => {}
  }

  if output.json {
    output.print_json(&serde_json::json!({"renamed": true, "name": name}));
  } else {
    println!("Session renamed to: {name}");
  }
  EXIT_SUCCESS
}

async fn resume(rest: &RestClient, output: &Output, session_id: &str) -> i32 {
  match rest
    .post_json::<_, ResumeSessionResponse>(
      &format!("/api/sessions/{session_id}/resume"),
      &serde_json::json!({}),
    )
    .await
    .into_result()
  {
    Ok(resp) => {
      let session = resp.session;
      if output.json {
        output.print_json_pretty(&SessionActionJsonResponse {
          ok: true,
          action: "resumed",
          session_id: session.id.clone(),
          source_session_id: None,
          summary: session_json_overview_from_summary(&session),
          session,
        });
      } else {
        println!(
          "Session resumed. Status: {}",
          work_status_str(&session.work_status)
        );
      }
      EXIT_SUCCESS
    }
    Err((code, err)) => {
      output.print_error(&err);
      code
    }
  }
}

// ── Streaming Helpers ────────────────────────────────────────

async fn stream_turn_events(ws: &mut WsClient, output: &Output) -> i32 {
  let timeout = Duration::from_secs(300);
  let mut saw_turn_activity = false;

  loop {
    match ws.recv_timeout(timeout).await {
      Ok(Some(ref msg)) => {
        if output.json {
          output.print_json(msg);
        }
        match msg {
          ServerMessage::ConversationRowsChanged { upserted, .. } => {
            if !upserted.is_empty() {
              saw_turn_activity = true;
            }
            if !output.json {
              for entry in upserted {
                let role = format_row_type_summary(&entry.row);
                let content = extract_row_content_str_summary(&entry.row);
                if !content.is_empty() {
                  println!("[{role}] {content}");
                }
              }
            }
          }
          ServerMessage::SessionDelta { changes, .. } => {
            if changes.work_status.is_some() || changes.last_message.is_some() {
              saw_turn_activity = true;
            }
            if !output.json {
              let dim = console::Style::new().dim();
              if let Some(status) = &changes.work_status {
                println!(
                  "{} work_status -> {}",
                  dim.apply_to("delta"),
                  work_status_str(status)
                );
                if stream_turn_should_exit(status, saw_turn_activity) {
                  return EXIT_SUCCESS;
                }
              }
              if let Some(Some(name)) = &changes.custom_name {
                println!("{} name -> {name}", dim.apply_to("delta"));
              }
              if let Some(Some(summary)) = &changes.summary {
                println!("{} summary -> {summary}", dim.apply_to("delta"));
              }
            } else if let Some(status) = &changes.work_status {
              if stream_turn_should_exit(status, saw_turn_activity) {
                return EXIT_SUCCESS;
              }
            }
          }
          ServerMessage::ApprovalRequested { request, .. } => {
            if !output.json {
              let tool = request.tool_name.as_deref().unwrap_or("unknown");
              let preview = request
                .command
                .as_deref()
                .or(request.tool_input.as_deref())
                .unwrap_or("(see request)");
              println!("\nApproval needed: {tool} — {preview}");
            }
            return EXIT_SUCCESS;
          }
          ServerMessage::SessionEnded { reason, .. } => {
            if !output.json {
              println!("Session ended: {reason}");
            }
            return EXIT_SUCCESS;
          }
          ServerMessage::Error { code, message, .. } => {
            output.print_error(&CliError::new(code.clone(), message.clone()));
            return EXIT_SERVER_ERROR;
          }
          _ => {}
        }
      }
      Ok(None) => {
        if !output.json {
          eprintln!("Connection closed or timed out.");
        }
        return EXIT_CONNECTION_ERROR;
      }
      Err(e) => {
        output.print_error(&CliError::connection(e.to_string()));
        return EXIT_CONNECTION_ERROR;
      }
    }
  }
}

fn format_row_type_summary(
  row: &orbitdock_protocol::conversation_contracts::ConversationRowSummary,
) -> &'static str {
  use orbitdock_protocol::conversation_contracts::ConversationRowSummary;
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

fn event_type_name(msg: &ServerMessage) -> &'static str {
  match msg {
    ServerMessage::Hello { .. } => "hello",
    ServerMessage::SessionDelta { .. } => "session_delta",
    ServerMessage::ConversationRowsChanged { .. } => "conversation_rows_changed",
    ServerMessage::ApprovalRequested { .. } => "approval_requested",
    ServerMessage::ApprovalDecisionResult { .. } => "approval_decision_result",
    ServerMessage::ApprovalDeleted { .. } => "approval_deleted",
    ServerMessage::ApprovalsList { .. } => "approvals_list",
    ServerMessage::TokensUpdated { .. } => "tokens_updated",
    ServerMessage::SessionEnded { .. } => "session_ended",
    ServerMessage::SessionForked { .. } => "session_forked",
    ServerMessage::ContextCompacted { .. } => "context_compacted",
    ServerMessage::UndoStarted { .. } => "undo_started",
    ServerMessage::UndoCompleted { .. } => "undo_completed",
    ServerMessage::ThreadRolledBack { .. } => "thread_rolled_back",
    ServerMessage::ShellStarted { .. } => "shell_started",
    ServerMessage::ShellOutput { .. } => "shell_output",
    ServerMessage::TurnDiffSnapshot { .. } => "turn_diff_snapshot",
    ServerMessage::RateLimitEvent { .. } => "rate_limit_event",
    ServerMessage::PromptSuggestion { .. } => "prompt_suggestion",
    ServerMessage::Error { .. } => "error",
    ServerMessage::ServerInfo { .. } => "server_info",
    ServerMessage::ModelsList { .. } => "models_list",
    ServerMessage::ReviewCommentCreated { .. } => "review_comment_created",
    ServerMessage::ReviewCommentUpdated { .. } => "review_comment_updated",
    ServerMessage::ReviewCommentDeleted { .. } => "review_comment_deleted",
    ServerMessage::ReviewCommentsList { .. } => "review_comments_list",
    ServerMessage::WorktreeCreated { .. } => "worktree_created",
    ServerMessage::WorktreeRemoved { .. } => "worktree_removed",
    ServerMessage::WorktreeStatusChanged { .. } => "worktree_status_changed",
    ServerMessage::WorktreeError { .. } => "worktree_error",
    ServerMessage::WorktreesList { .. } => "worktrees_list",
    ServerMessage::CodexAccountStatus { .. } => "codex_account_status",
    ServerMessage::CodexAccountUpdated { .. } => "codex_account_updated",
    ServerMessage::CodexLoginChatgptStarted { .. } => "codex_login_started",
    ServerMessage::CodexLoginChatgptCompleted { .. } => "codex_login_completed",
    ServerMessage::CodexLoginChatgptCanceled { .. } => "codex_login_canceled",
    ServerMessage::ClaudeCapabilities { .. } => "claude_capabilities",
    ServerMessage::ClaudeUsageResult { .. } => "claude_usage_result",
    ServerMessage::CodexUsageResult { .. } => "codex_usage_result",
    ServerMessage::FilesPersisted { .. } => "files_persisted",
    ServerMessage::McpToolsList { .. } => "mcp_tools_list",
    ServerMessage::McpStartupUpdate { .. } => "mcp_startup_update",
    ServerMessage::McpStartupComplete { .. } => "mcp_startup_complete",
    ServerMessage::SkillsList { .. } => "skills_list",
    ServerMessage::SkillsUpdateAvailable { .. } => "skills_update_available",
    ServerMessage::SubagentToolsList { .. } => "subagent_tools_list",
    ServerMessage::OpenAiKeyStatus { .. } => "openai_key_status",
    ServerMessage::DirectoryListing { .. } => "directory_listing",
    ServerMessage::RecentProjectsList { .. } => "recent_projects_list",
    ServerMessage::PermissionRules { .. } => "permission_rules",
    ServerMessage::DashboardInvalidated { .. } => "dashboard_invalidated",
    ServerMessage::MissionsInvalidated { .. } => "missions_invalidated",
    ServerMessage::MissionsList { .. } => "missions_list",
    ServerMessage::MissionDelta { .. } => "mission_delta",
    ServerMessage::MissionHeartbeat { .. } => "mission_heartbeat",
    ServerMessage::SteerOutcome { .. } => "steer_outcome",
    ServerMessage::UpdateAvailable { .. } => "update_available",
    ServerMessage::TerminalCreated { .. } => "terminal_created",
    ServerMessage::TerminalExited { .. } => "terminal_exited",
  }
}

fn print_watch_event(msg: &ServerMessage) {
  let dim = console::Style::new().dim();
  let bold = console::Style::new().bold();

  match msg {
    ServerMessage::Hello { hello } => {
      println!(
        "{} version {} (min client {})",
        dim.apply_to("hello"),
        hello.server_version,
        hello.minimum_client_version
      );
    }
    ServerMessage::SessionDelta { changes, .. } => {
      if let Some(status) = &changes.work_status {
        println!(
          "{} work_status -> {}",
          dim.apply_to("delta"),
          work_status_str(status)
        );
      }
      if let Some(Some(name)) = &changes.custom_name {
        println!("{} name -> {name}", dim.apply_to("delta"));
      }
      if let Some(Some(summary)) = &changes.summary {
        println!("{} summary -> {summary}", dim.apply_to("delta"));
      }
    }
    ServerMessage::ConversationRowsChanged { upserted, .. } => {
      for entry in upserted {
        let role = format_row_type_summary(&entry.row);
        let content = extract_row_content_str_summary(&entry.row);
        let content = truncate(&content, 120);
        println!("{} [{role}] {content}", bold.apply_to("+row"));
      }
    }
    ServerMessage::ApprovalRequested { request, .. } => {
      let coral = console::Style::new().red().bold();
      println!(
        "{} {} — {}",
        coral.apply_to("approval"),
        request.tool_name.as_deref().unwrap_or("unknown"),
        request.id
      );
    }
    ServerMessage::ApprovalDecisionResult {
      outcome,
      request_id,
      ..
    } => {
      println!("{} {outcome} ({request_id})", dim.apply_to("decision"));
    }
    ServerMessage::TokensUpdated { usage, .. } => {
      let fill = usage.context_fill_percent();
      println!(
        "{} {fill:.0}% ({} in / {} out)",
        dim.apply_to("tokens"),
        usage.input_tokens,
        usage.output_tokens
      );
    }
    ServerMessage::SessionEnded { reason, .. } => {
      println!("{} {reason}", bold.apply_to("ended"));
    }
    ServerMessage::ContextCompacted { .. } => {
      println!("{}", dim.apply_to("context compacted"));
    }
    ServerMessage::UndoCompleted { success, .. } => {
      println!("{} success={success}", dim.apply_to("undo"));
    }
    ServerMessage::ShellStarted { command, .. } => {
      println!("{} {command}", bold.apply_to("shell"));
    }
    ServerMessage::ShellOutput {
      stdout,
      stderr,
      exit_code,
      ..
    } => {
      if !stdout.is_empty() {
        print!("{stdout}");
      }
      if !stderr.is_empty() {
        eprint!("{stderr}");
      }
      if let Some(code) = exit_code {
        println!("{} exit {code}", dim.apply_to("shell"));
      }
    }
    ServerMessage::Error { code, message, .. } => {
      let red = console::Style::new().red();
      println!("{} [{code}] {message}", red.apply_to("error"));
    }
    _ => {
      println!("{} {}", dim.apply_to("event"), event_type_name(msg));
    }
  }
}

fn print_conversation_snapshot_rows(
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

// ── Human Output ─────────────────────────────────────────────

fn print_session_detail(session: &SessionState) {
  let bold = console::Style::new().bold();
  let project = project_label(session.project_name.as_deref(), &session.project_path);

  println!("{} {}", bold.apply_to("Session:"), session.id);
  println!(
    "{} {}",
    bold.apply_to("Provider:"),
    provider_str(&session.provider)
  );
  println!(
    "{} {} ({})",
    bold.apply_to("Project:"),
    project,
    session.project_path
  );
  println!(
    "{} {} / {}",
    bold.apply_to("Status:"),
    session_status_str(&session.status),
    work_status_str(&session.work_status)
  );
  println!(
    "{} {} / {}",
    bold.apply_to("Mode:"),
    control_mode_str(&session.control_mode),
    lifecycle_state_str(&session.lifecycle_state)
  );

  if let Some(ref model) = session.model {
    println!("{} {}", bold.apply_to("Model:"), model);
  }
  if let Some(ref name) = session.custom_name {
    println!("{} {}", bold.apply_to("Name:"), name);
  }
  if let Some(ref summary) = session.summary {
    println!("{} {}", bold.apply_to("Summary:"), summary);
  }
  if let Some(ref branch) = session.git_branch {
    println!("{} {}", bold.apply_to("Branch:"), branch);
  }
  if let Some(ref sha) = session.git_sha {
    println!("{} {}", bold.apply_to("Commit:"), sha);
  }
  if let Some(ref permission_mode) = session.permission_mode {
    println!("{} {}", bold.apply_to("Permissions:"), permission_mode);
  }
  if let Some(ref approval_policy) = session.approval_policy {
    println!("{} {}", bold.apply_to("Approval policy:"), approval_policy);
  }
  if let Some(ref effort) = session.effort {
    println!("{} {}", bold.apply_to("Effort:"), effort);
  }
  if let Some(ref started_at) = session.started_at {
    println!("{} {}", bold.apply_to("Started:"), started_at);
  }
  if let Some(ref last_activity_at) = session.last_activity_at {
    println!("{} {}", bold.apply_to("Last activity:"), last_activity_at);
  }
  if let Some(ref last_progress_at) = session.last_progress_at {
    println!("{} {}", bold.apply_to("Last progress:"), last_progress_at);
  }
  if let Some(ref pending_tool_name) = session.pending_tool_name {
    println!("{} {}", bold.apply_to("Pending tool:"), pending_tool_name);
  }
  if let Some(ref pending_question) = session.pending_question {
    println!(
      "{} {}",
      bold.apply_to("Pending question:"),
      detail_preview(pending_question)
    );
  }
  if let Some(ref first_prompt) = session.first_prompt {
    println!(
      "{} {}",
      bold.apply_to("First prompt:"),
      detail_preview(first_prompt)
    );
  }
  if let Some(ref last_message) = session.last_message {
    println!(
      "{} {}",
      bold.apply_to("Last message:"),
      detail_preview(last_message)
    );
  }

  let usage = &session.token_usage;
  if usage.context_window > 0 {
    let fill = usage.context_fill_percent();
    println!(
      "{} {:.0}% ({} in / {} out / {} cached / {} window)",
      bold.apply_to("Context:"),
      fill,
      usage.input_tokens,
      usage.output_tokens,
      usage.cached_tokens,
      usage.context_window,
    );
  }
}

fn print_conversation_snapshot(snapshot: Option<&ConversationSnapshotPage>) {
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

#[cfg(test)]
mod tests {
  use serde_json::Value;

  use super::{
    build_session_list_json_response, session_json_overview_from_state, stream_turn_should_exit,
  };
  use orbitdock_protocol::{
    Provider, SessionControlMode, SessionLifecycleState, SessionListItem, SessionListStatus,
    SessionState, SessionStatus, TokenUsage, TokenUsageSnapshotKind, WorkStatus,
  };

  fn sample_state() -> SessionState {
    SessionState {
      id: "od-session-123".to_string(),
      provider: Provider::Claude,
      project_path: "/tmp/orbitdock".to_string(),
      transcript_path: None,
      project_name: Some("OrbitDock".to_string()),
      model: Some("claude-opus-4-6".to_string()),
      custom_name: None,
      summary: Some("CLI output formatter".to_string()),
      first_prompt: Some("Make the CLI easier to read for people and LLMs".to_string()),
      last_message: Some("Session output is looking much better now.".to_string()),
      status: SessionStatus::Active,
      work_status: WorkStatus::Waiting,
      control_mode: SessionControlMode::Direct,
      lifecycle_state: SessionLifecycleState::Open,
      accepts_user_input: true,
      steerable: true,
      pending_approval: None,
      permission_mode: Some("acceptEdits".to_string()),
      allow_bypass_permissions: false,
      collaboration_mode: None,
      multi_agent: None,
      personality: None,
      service_tier: None,
      developer_instructions: None,
      codex_config_mode: None,
      codex_config_profile: None,
      codex_model_provider: None,
      codex_config_source: None,
      codex_config_overrides: None,
      pending_tool_name: Some("apply_patch".to_string()),
      pending_tool_input: None,
      pending_question: Some("Should the IDs stay fully visible?".to_string()),
      pending_approval_id: None,
      token_usage: TokenUsage {
        input_tokens: 1200,
        output_tokens: 300,
        cached_tokens: 600,
        context_window: 10_000,
      },
      token_usage_snapshot_kind: TokenUsageSnapshotKind::MixedLegacy,
      current_diff: None,
      cumulative_diff: None,
      current_plan: None,
      codex_integration_mode: None,
      claude_integration_mode: None,
      approval_policy: Some("on-request".to_string()),
      approval_policy_details: None,
      sandbox_mode: None,
      started_at: Some("2026-03-26T14:51:01Z".to_string()),
      last_activity_at: Some("2026-03-26T15:08:29Z".to_string()),
      last_progress_at: Some("2026-03-26T15:08:29Z".to_string()),
      forked_from_session_id: None,
      revision: Some(383),
      current_turn_id: None,
      turn_count: 2,
      turn_diffs: vec![],
      git_branch: Some("main".to_string()),
      git_sha: Some("e6b1b46a79b2".to_string()),
      current_cwd: None,
      subagents: vec![],
      effort: Some("medium".to_string()),
      terminal_session_id: None,
      terminal_app: None,
      approval_version: Some(0),
      repository_root: Some("/tmp/orbitdock".to_string()),
      is_worktree: false,
      worktree_id: None,
      unread_count: 0,
      mission_id: None,
      issue_identifier: None,
      rows: vec![],
      total_row_count: 0,
      has_more_before: false,
      oldest_sequence: None,
      newest_sequence: None,
    }
  }

  #[test]
  fn stream_turn_waiting_requires_real_turn_activity() {
    assert!(!stream_turn_should_exit(&WorkStatus::Waiting, false));
    assert!(stream_turn_should_exit(&WorkStatus::Waiting, true));
  }

  #[test]
  fn stream_turn_exit_rules_match_user_visible_completion() {
    assert!(!stream_turn_should_exit(&WorkStatus::Working, true));
    assert!(stream_turn_should_exit(&WorkStatus::Permission, true));
    assert!(stream_turn_should_exit(&WorkStatus::Reply, true));
    assert!(stream_turn_should_exit(&WorkStatus::Ended, true));
  }

  #[test]
  fn session_json_overview_from_state_derives_compact_high_signal_fields() {
    let overview = session_json_overview_from_state(&sample_state());
    let value = serde_json::to_value(&overview).expect("serialize overview");

    assert_eq!(
      value["project_label"],
      Value::String("OrbitDock".to_string())
    );
    assert_eq!(
      value["title"],
      Value::String("CLI output formatter".to_string())
    );
    assert_eq!(
      value["context_line"],
      Value::String("Session output is looking much better now.".to_string())
    );
    assert_eq!(value["context_fill_percent"], Value::from(12.0));
    assert_eq!(
      value["token_usage_snapshot_kind"],
      Value::String("mixed_legacy".to_string())
    );
    assert_eq!(value["cache_hit_percent"], Value::from(50.0));
  }

  #[test]
  fn session_list_json_response_includes_count_and_summaries() {
    let response = build_session_list_json_response(vec![SessionListItem {
      id: "od-session-123".to_string(),
      provider: Provider::Claude,
      project_path: "/tmp/orbitdock".to_string(),
      project_name: Some("OrbitDock".to_string()),
      git_branch: Some("main".to_string()),
      model: Some("claude-opus-4-6".to_string()),
      status: SessionStatus::Active,
      work_status: WorkStatus::Waiting,
      control_mode: SessionControlMode::Direct,
      lifecycle_state: SessionLifecycleState::Open,
      steerable: true,
      codex_integration_mode: None,
      claude_integration_mode: None,
      started_at: None,
      last_activity_at: None,
      last_progress_at: None,
      unread_count: 0,
      has_turn_diff: false,
      pending_tool_name: None,
      repository_root: None,
      is_worktree: false,
      worktree_id: None,
      total_tokens: 1500,
      total_cost_usd: 0.0,
      input_tokens: 1200,
      output_tokens: 300,
      cached_tokens: 600,
      display_title: "CLI output formatter".to_string(),
      context_line: Some("Session output is looking much better now.".to_string()),
      list_status: SessionListStatus::Working,
      effort: Some("medium".to_string()),
      summary_revision: 0,
      active_worker_count: 0,
      pending_tool_family: None,
      forked_from_session_id: None,
      mission_id: None,
      issue_identifier: None,
    }]);
    let value = serde_json::to_value(&response).expect("serialize response");

    assert_eq!(value["kind"], Value::String("session_list".to_string()));
    assert_eq!(value["count"], Value::from(1));
    assert_eq!(
      value["summaries"][0]["title"],
      Value::String("CLI output formatter".to_string())
    );
    assert_eq!(
      value["summaries"][0]["context_line"],
      Value::String("Session output is looking much better now.".to_string())
    );
    assert!(value["summaries"][0].get("cache_hit_percent").is_none());
  }

  #[test]
  fn session_summary_context_line_is_compacted_for_json_overview() {
    let response = build_session_list_json_response(vec![SessionListItem {
      id: "od-session-456".to_string(),
      provider: Provider::Claude,
      project_path: "/tmp/orbitdock".to_string(),
      project_name: Some("OrbitDock".to_string()),
      git_branch: Some("main".to_string()),
      model: Some("claude-opus-4-6".to_string()),
      status: SessionStatus::Active,
      work_status: WorkStatus::Waiting,
      control_mode: SessionControlMode::Direct,
      lifecycle_state: SessionLifecycleState::Open,
      steerable: true,
      codex_integration_mode: None,
      claude_integration_mode: None,
      started_at: None,
      last_activity_at: None,
      last_progress_at: None,
      unread_count: 0,
      has_turn_diff: false,
      pending_tool_name: None,
      repository_root: None,
      is_worktree: false,
      worktree_id: None,
      total_tokens: 10,
      total_cost_usd: 0.0,
      input_tokens: 5,
      output_tokens: 5,
      cached_tokens: 0,
      display_title: "CLI output formatter".to_string(),
      context_line: Some("First line\n\nSecond line with extra spacing".to_string()),
      list_status: SessionListStatus::Working,
      effort: Some("medium".to_string()),
      summary_revision: 0,
      active_worker_count: 0,
      pending_tool_family: None,
      forked_from_session_id: None,
      mission_id: None,
      issue_identifier: None,
    }]);
    let value = serde_json::to_value(&response).expect("serialize response");

    assert_eq!(
      value["summaries"][0]["context_line"],
      Value::String("First line Second line with extra spacing".to_string())
    );
  }

  #[test]
  fn session_json_overview_omits_impossible_cache_hit_percent() {
    let mut state = sample_state();
    state.token_usage.input_tokens = 3;
    state.token_usage.cached_tokens = 41_696;

    let value =
      serde_json::to_value(session_json_overview_from_state(&state)).expect("serialize overview");

    assert!(value.get("cache_hit_percent").is_none());
    assert_eq!(
      value["token_usage_snapshot_kind"],
      Value::String("mixed_legacy".to_string())
    );
  }
}
