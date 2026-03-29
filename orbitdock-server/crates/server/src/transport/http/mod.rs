use std::sync::Arc;

mod approvals;
mod capabilities;
mod codex_auth;
mod connector_actions;
mod errors;
mod files;
pub(crate) mod mission_control;
mod permissions;
mod review_comments;
mod router;
mod server_info;
mod server_meta;
mod session_actions;
mod session_lifecycle;
mod sessions;
mod shell;
mod sync;
#[cfg(test)]
mod test_support;
mod update;
mod worktrees;

use axum::{
  body::Bytes,
  extract::{Path, Query, State},
  http::{header::CONTENT_TYPE, HeaderMap, StatusCode},
  response::IntoResponse,
  Json,
};
use orbitdock_protocol::{
  ApprovalHistoryItem, ImageInput, MentionInput, SessionSummary, SkillInput,
};
use serde::{Deserialize, Serialize};
use tracing::{error, info};

use crate::infrastructure::persistence::{delete_approval, list_approvals, PersistCommand};
use crate::runtime::session_queries::{
  load_conversation_bootstrap, load_conversation_page, load_full_session_state, SessionLoadError,
};
use crate::runtime::session_registry::SessionRegistry;

pub use approvals::{
  answer_question, approve_tool, delete_approval_endpoint, list_approvals_endpoint,
  respond_to_permission_request,
};
pub use capabilities::{
  apply_flag_settings, get_session_instructions, install_plugin, list_mcp_tools_endpoint,
  list_plugins_endpoint, list_skills_endpoint, mcp_authenticate, mcp_clear_auth, mcp_set_servers,
  refresh_mcp_servers, toggle_mcp_server, uninstall_plugin,
};
pub use codex_auth::{codex_login_cancel, codex_login_start, codex_logout, read_codex_account};
pub(crate) use connector_actions::{
  dispatch_error_response, messaging_dispatch_error_response, session_not_found_error,
};
pub(crate) use errors::{revision_now, ApiErrorResponse, ApiResult};
pub use files::{
  browse_directory, git_init_endpoint, list_recent_projects, list_subagent_messages_endpoint,
  list_subagent_tools_endpoint,
};
pub use mission_control::{
  adopt_global_tracker_key, check_github_key, check_linear_key, create_mission, delete_github_key,
  delete_linear_key, delete_mission, delete_mission_tracker_key, dispatch_mission_issue,
  get_default_template, get_mission, get_mission_defaults, get_mission_tracker_key,
  get_tracker_keys, list_mission_issues, list_mission_worktrees, list_missions,
  migrate_workflow_to_mission, report_issue_blocked, report_issue_completed, retry_mission_issue,
  scaffold_mission_file, set_github_key, set_issue_pr_url, set_linear_key, set_mission_tracker_key,
  start_mission_orchestrator_endpoint, transition_mission_issue, trigger_mission_poll,
  update_mission, update_mission_defaults, update_mission_settings,
};
pub use permissions::{add_permission_rule, get_permission_rules, remove_permission_rule};
pub use review_comments::{
  create_review_comment_endpoint, delete_review_comment_by_id, list_review_comments_endpoint,
  update_review_comment,
};
pub use router::build_router;
pub use server_info::{
  check_open_ai_key, get_server_meta, get_workspace_provider, get_workspace_provider_config_value,
  set_client_primary_claim, set_open_ai_key, set_server_role, set_workspace_provider,
  set_workspace_provider_config_value, test_workspace_provider,
};
pub use server_meta::{
  fetch_claude_usage, fetch_codex_usage, list_claude_models, list_codex_models,
};
pub use session_actions::{
  compact_context, get_session_image_attachment, interrupt_session, post_session_message,
  post_steer_turn, rewind_files, rollback_turns, stop_task, undo_last_turn,
  upload_session_image_attachment, AcceptedResponse,
};
pub use session_lifecycle::{
  batch_write_codex_config, create_session, end_session, fork_session,
  fork_session_to_existing_worktree, fork_session_to_worktree, get_codex_config_catalog,
  get_codex_config_documents, get_codex_preferences, inspect_codex_config, rename_session,
  resume_session, set_summary, takeover_session, update_codex_preferences, update_session_config,
  write_codex_config_value,
};
pub use sessions::{
  get_conversation_history, get_conversation_snapshot, get_dashboard_snapshot, get_row_content,
  get_session_composer, get_session_detail, get_session_stats, mark_session_read,
  search_conversation_rows,
};
pub use shell::{cancel_shell_endpoint, execute_shell_endpoint};
pub use sync::post_sync_batch;
pub use update::{
  check_update, get_update_channel, get_update_status, set_update_channel, start_upgrade,
};
pub use worktrees::{create_worktree, discover_worktrees, list_worktrees, remove_worktree};
