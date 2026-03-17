use std::sync::Arc;

mod approvals;
mod capabilities;
mod codex_auth;
mod connector_actions;
mod errors;
mod files;
mod mission_control;
mod permissions;
mod review_comments;
mod router;
mod server_info;
mod server_meta;
mod session_actions;
mod session_lifecycle;
mod sessions;
mod shell;
#[cfg(test)]
mod test_support;
mod worktrees;

use axum::{
    body::Bytes,
    extract::{Path, Query, State},
    http::{header::CONTENT_TYPE, HeaderMap, StatusCode},
    response::IntoResponse,
    Json,
};
use orbitdock_protocol::{
    ApprovalHistoryItem, ImageInput, MentionInput, SessionState, SessionSummary, SkillInput,
};
use serde::{Deserialize, Serialize};
use tracing::{error, info};

use crate::infrastructure::persistence::{
    delete_approval, list_approvals, load_messages_for_session, PersistCommand,
};
use crate::runtime::session_queries::{
    load_conversation_bootstrap, load_conversation_page, load_full_session_state, SessionLoadError,
};
use crate::runtime::session_registry::SessionRegistry;

pub use approvals::{
    answer_question, approve_tool, delete_approval_endpoint, list_approvals_endpoint,
    respond_to_permission_request,
};
pub use capabilities::{
    apply_flag_settings, download_remote_skill, get_session_instructions, list_mcp_tools_endpoint,
    list_remote_skills_endpoint, list_skills_endpoint, mcp_authenticate, mcp_clear_auth,
    mcp_set_servers, refresh_mcp_servers, toggle_mcp_server,
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
    check_linear_key, create_mission, delete_linear_key, delete_mission, dispatch_mission_issue,
    get_default_template, get_mission, get_mission_defaults, get_tracker_keys, list_mission_issues,
    list_missions, migrate_workflow_to_mission, report_issue_blocked, retry_mission_issue,
    scaffold_mission_file, set_linear_key, start_mission_orchestrator_endpoint, update_mission,
    update_mission_defaults, update_mission_settings,
};
pub use permissions::{add_permission_rule, get_permission_rules, remove_permission_rule};
pub use review_comments::{
    create_review_comment_endpoint, delete_review_comment_by_id, list_review_comments_endpoint,
    update_review_comment,
};
pub use router::build_router;
pub use server_info::{
    check_open_ai_key, set_client_primary_claim, set_open_ai_key, set_server_role,
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
    create_session, end_session, fork_session, fork_session_to_existing_worktree,
    fork_session_to_worktree, rename_session, resume_session, takeover_session,
    update_session_config,
};
pub use sessions::{
    get_conversation_bootstrap, get_conversation_history, get_row_content, get_session,
    get_session_stats, list_sessions, mark_session_read, search_conversation_rows,
};
pub use shell::{cancel_shell_endpoint, execute_shell_endpoint};
pub use worktrees::{create_worktree, discover_worktrees, list_worktrees, remove_worktree};
