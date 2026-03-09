use std::sync::Arc;

use axum::{
    routing::{delete, get, patch, post, put},
    Router,
};

use crate::domain::sessions::registry::SessionRegistry;

pub fn build_router() -> Router<Arc<SessionRegistry>> {
    Router::new()
        .route(
            "/api/hook",
            post(crate::connectors::hook_handler::hook_handler),
        )
        .route("/api/sessions", get(super::list_sessions))
        .route("/api/sessions/{session_id}", get(super::get_session))
        .route(
            "/api/sessions/{session_id}/conversation",
            get(super::get_conversation_bootstrap),
        )
        .route(
            "/api/sessions/{session_id}/messages",
            get(super::get_conversation_history).post(super::post_session_message),
        )
        .route(
            "/api/sessions/{session_id}/steer",
            post(super::post_steer_turn),
        )
        .route(
            "/api/sessions/{session_id}/attachments/images",
            post(super::upload_session_image_attachment),
        )
        .route(
            "/api/sessions/{session_id}/attachments/images/{attachment_id}",
            get(super::get_session_image_attachment),
        )
        .route("/api/approvals", get(super::list_approvals_endpoint))
        .route(
            "/api/approvals/{approval_id}",
            delete(super::delete_approval_endpoint),
        )
        .route(
            "/api/server/openai-key",
            get(super::check_open_ai_key).post(super::set_open_ai_key),
        )
        .route("/api/server/role", put(super::set_server_role))
        .route("/api/usage/codex", get(super::fetch_codex_usage))
        .route("/api/usage/claude", get(super::fetch_claude_usage))
        .route("/api/models/codex", get(super::list_codex_models))
        .route("/api/models/claude", get(super::list_claude_models))
        .route("/api/codex/account", get(super::read_codex_account))
        .route("/api/codex/login/start", post(super::codex_login_start))
        .route("/api/codex/login/cancel", post(super::codex_login_cancel))
        .route("/api/codex/logout", post(super::codex_logout))
        .route(
            "/api/sessions/{session_id}/mark-read",
            post(super::mark_session_read),
        )
        .route(
            "/api/sessions/{session_id}/review-comments",
            get(super::list_review_comments_endpoint).post(super::create_review_comment_endpoint),
        )
        .route(
            "/api/review-comments/{comment_id}",
            patch(super::update_review_comment).delete(super::delete_review_comment_by_id),
        )
        .route(
            "/api/sessions/{session_id}/subagents/{subagent_id}/tools",
            get(super::list_subagent_tools_endpoint),
        )
        .route(
            "/api/sessions/{session_id}/skills",
            get(super::list_skills_endpoint),
        )
        .route(
            "/api/sessions/{session_id}/skills/remote",
            get(super::list_remote_skills_endpoint),
        )
        .route(
            "/api/sessions/{session_id}/mcp/tools",
            get(super::list_mcp_tools_endpoint),
        )
        .route(
            "/api/worktrees",
            get(super::list_worktrees).post(super::create_worktree),
        )
        .route("/api/worktrees/discover", post(super::discover_worktrees))
        .route(
            "/api/worktrees/{worktree_id}",
            delete(super::remove_worktree),
        )
        .route(
            "/api/sessions/{session_id}/skills/download",
            post(super::download_remote_skill),
        )
        .route(
            "/api/sessions/{session_id}/mcp/refresh",
            post(super::refresh_mcp_servers),
        )
        .route(
            "/api/sessions/{session_id}/mcp/toggle",
            post(super::toggle_mcp_server),
        )
        .route(
            "/api/sessions/{session_id}/mcp/authenticate",
            post(super::mcp_authenticate),
        )
        .route(
            "/api/sessions/{session_id}/mcp/clear-auth",
            post(super::mcp_clear_auth),
        )
        .route(
            "/api/sessions/{session_id}/mcp/servers",
            post(super::mcp_set_servers),
        )
        .route(
            "/api/sessions/{session_id}/flags",
            post(super::apply_flag_settings),
        )
        .route(
            "/api/sessions/{session_id}/permissions",
            get(super::get_permission_rules),
        )
        .route(
            "/api/sessions/{session_id}/permissions/rules",
            post(super::add_permission_rule).delete(super::remove_permission_rule),
        )
        .route("/api/git/init", post(super::git_init_endpoint))
        .route("/api/fs/browse", get(super::browse_directory))
        .route("/api/fs/recent-projects", get(super::list_recent_projects))
        .route(
            "/api/sessions/{session_id}/interrupt",
            post(super::interrupt_session),
        )
        .route(
            "/api/sessions/{session_id}/compact",
            post(super::compact_context),
        )
        .route(
            "/api/sessions/{session_id}/undo",
            post(super::undo_last_turn),
        )
        .route(
            "/api/sessions/{session_id}/rollback",
            post(super::rollback_turns),
        )
        .route(
            "/api/sessions/{session_id}/stop-task",
            post(super::stop_task),
        )
        .route(
            "/api/sessions/{session_id}/rewind-files",
            post(super::rewind_files),
        )
        .route(
            "/api/sessions/{session_id}/approve",
            post(super::approve_tool),
        )
        .route(
            "/api/sessions/{session_id}/answer",
            post(super::answer_question),
        )
        .route(
            "/api/sessions/{session_id}/name",
            patch(super::rename_session),
        )
        .route(
            "/api/sessions/{session_id}/config",
            patch(super::update_session_config),
        )
        .route("/api/sessions/{session_id}/end", post(super::end_session))
        .route(
            "/api/sessions/{session_id}/shell/exec",
            post(super::execute_shell_endpoint),
        )
        .route(
            "/api/sessions/{session_id}/shell/cancel",
            post(super::cancel_shell_endpoint),
        )
        .route(
            "/api/client/primary-claim",
            post(super::set_client_primary_claim),
        )
        .route("/api/sessions", post(super::create_session))
        .route(
            "/api/sessions/{session_id}/resume",
            post(super::resume_session),
        )
        .route(
            "/api/sessions/{session_id}/takeover",
            post(super::takeover_session),
        )
        .route("/api/sessions/{session_id}/fork", post(super::fork_session))
        .route(
            "/api/sessions/{session_id}/fork-to-worktree",
            post(super::fork_session_to_worktree),
        )
        .route(
            "/api/sessions/{session_id}/fork-to-existing-worktree",
            post(super::fork_session_to_existing_worktree),
        )
}
