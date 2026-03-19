use std::sync::Arc;

use axum::{
    routing::{delete, get, patch, post, put},
    Router,
};

use crate::runtime::session_registry::SessionRegistry;

pub fn build_router() -> Router<Arc<SessionRegistry>> {
    Router::new()
        .merge(hook_routes())
        .merge(session_read_routes())
        .merge(session_write_routes())
        .merge(session_lifecycle_routes())
        .merge(session_action_routes())
        .merge(session_attachment_routes())
        .merge(session_capability_routes())
        .merge(approval_routes())
        .merge(review_routes())
        .merge(server_routes())
        .merge(filesystem_routes())
        .merge(worktree_routes())
        .merge(mission_routes())
}

fn hook_routes() -> Router<Arc<SessionRegistry>> {
    Router::new().route(
        "/api/hook",
        post(crate::connectors::hook_handler::hook_handler),
    )
}

fn session_read_routes() -> Router<Arc<SessionRegistry>> {
    Router::new()
        .route("/api/sessions", get(super::list_sessions))
        .route("/api/sessions/{session_id}", get(super::get_session))
        .route(
            "/api/sessions/{session_id}/conversation",
            get(super::get_conversation_bootstrap),
        )
        .route(
            "/api/sessions/{session_id}/messages",
            get(super::get_conversation_history),
        )
        .route(
            "/api/sessions/{session_id}/search",
            get(super::search_conversation_rows),
        )
        .route(
            "/api/sessions/{session_id}/stats",
            get(super::get_session_stats),
        )
        .route(
            "/api/sessions/{session_id}/rows/{row_id}/content",
            get(super::get_row_content),
        )
        .route(
            "/api/sessions/{session_id}/mark-read",
            post(super::mark_session_read),
        )
}

fn session_write_routes() -> Router<Arc<SessionRegistry>> {
    Router::new()
        .route("/api/sessions", post(super::create_session))
        .route(
            "/api/sessions/{session_id}/messages",
            post(super::post_session_message),
        )
        .route(
            "/api/sessions/{session_id}/steer",
            post(super::post_steer_turn),
        )
        .route(
            "/api/sessions/{session_id}/name",
            patch(super::rename_session),
        )
        .route(
            "/api/sessions/{session_id}/config",
            patch(super::update_session_config),
        )
}

fn session_lifecycle_routes() -> Router<Arc<SessionRegistry>> {
    Router::new()
        .route(
            "/api/sessions/{session_id}/resume",
            post(super::resume_session),
        )
        .route(
            "/api/sessions/{session_id}/takeover",
            post(super::takeover_session),
        )
        .route("/api/sessions/{session_id}/end", post(super::end_session))
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

fn session_action_routes() -> Router<Arc<SessionRegistry>> {
    Router::new()
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
            "/api/sessions/{session_id}/permissions/respond",
            post(super::respond_to_permission_request),
        )
}

fn session_attachment_routes() -> Router<Arc<SessionRegistry>> {
    Router::new()
        .route(
            "/api/sessions/{session_id}/attachments/images",
            post(super::upload_session_image_attachment),
        )
        .route(
            "/api/sessions/{session_id}/attachments/images/{attachment_id}",
            get(super::get_session_image_attachment),
        )
        .route(
            "/api/sessions/{session_id}/shell/exec",
            post(super::execute_shell_endpoint),
        )
        .route(
            "/api/sessions/{session_id}/shell/cancel",
            post(super::cancel_shell_endpoint),
        )
}

fn session_capability_routes() -> Router<Arc<SessionRegistry>> {
    Router::new()
        .route(
            "/api/sessions/{session_id}/subagents/{subagent_id}/tools",
            get(super::list_subagent_tools_endpoint),
        )
        .route(
            "/api/sessions/{session_id}/subagents/{subagent_id}/messages",
            get(super::list_subagent_messages_endpoint),
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
            "/api/sessions/{session_id}/skills/download",
            post(super::download_remote_skill),
        )
        .route(
            "/api/sessions/{session_id}/mcp/tools",
            get(super::list_mcp_tools_endpoint),
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
            "/api/sessions/{session_id}/instructions",
            get(super::get_session_instructions),
        )
        .route(
            "/api/sessions/{session_id}/permissions",
            get(super::get_permission_rules),
        )
        .route(
            "/api/sessions/{session_id}/permissions/rules",
            post(super::add_permission_rule).delete(super::remove_permission_rule),
        )
}

fn approval_routes() -> Router<Arc<SessionRegistry>> {
    Router::new()
        .route("/api/approvals", get(super::list_approvals_endpoint))
        .route(
            "/api/approvals/{approval_id}",
            delete(super::delete_approval_endpoint),
        )
}

fn review_routes() -> Router<Arc<SessionRegistry>> {
    Router::new()
        .route(
            "/api/sessions/{session_id}/review-comments",
            get(super::list_review_comments_endpoint).post(super::create_review_comment_endpoint),
        )
        .route(
            "/api/review-comments/{comment_id}",
            patch(super::update_review_comment).delete(super::delete_review_comment_by_id),
        )
}

fn server_routes() -> Router<Arc<SessionRegistry>> {
    Router::new()
        .route(
            "/api/server/openai-key",
            get(super::check_open_ai_key).post(super::set_open_ai_key),
        )
        .route("/api/server/role", put(super::set_server_role))
        .route(
            "/api/client/primary-claim",
            post(super::set_client_primary_claim),
        )
        .route("/api/usage/codex", get(super::fetch_codex_usage))
        .route("/api/usage/claude", get(super::fetch_claude_usage))
        .route("/api/models/codex", get(super::list_codex_models))
        .route("/api/models/claude", get(super::list_claude_models))
        .route("/api/codex/account", get(super::read_codex_account))
        .route(
            "/api/codex/config/inspect",
            post(super::inspect_codex_config),
        )
        .route("/api/codex/login/start", post(super::codex_login_start))
        .route("/api/codex/login/cancel", post(super::codex_login_cancel))
        .route("/api/codex/logout", post(super::codex_logout))
        .route(
            "/api/server/codex-preferences",
            get(super::get_codex_preferences).put(super::update_codex_preferences),
        )
}

fn filesystem_routes() -> Router<Arc<SessionRegistry>> {
    Router::new()
        .route("/api/git/init", post(super::git_init_endpoint))
        .route("/api/fs/browse", get(super::browse_directory))
        .route("/api/fs/recent-projects", get(super::list_recent_projects))
}

fn worktree_routes() -> Router<Arc<SessionRegistry>> {
    Router::new()
        .route(
            "/api/worktrees",
            get(super::list_worktrees).post(super::create_worktree),
        )
        .route("/api/worktrees/discover", post(super::discover_worktrees))
        .route(
            "/api/worktrees/{worktree_id}",
            delete(super::remove_worktree),
        )
}

fn mission_routes() -> Router<Arc<SessionRegistry>> {
    Router::new()
        .route(
            "/api/missions",
            get(super::list_missions).post(super::create_mission),
        )
        .route(
            "/api/missions/{mission_id}",
            get(super::get_mission)
                .put(super::update_mission)
                .delete(super::delete_mission),
        )
        .route(
            "/api/missions/{mission_id}/issues",
            get(super::list_mission_issues),
        )
        .route(
            "/api/missions/{mission_id}/issues/{issue_id}/retry",
            post(super::retry_mission_issue),
        )
        .route(
            "/api/missions/{mission_id}/issues/{issue_id}/blocked",
            post(super::report_issue_blocked),
        )
        .route(
            "/api/missions/{mission_id}/scaffold",
            post(super::scaffold_mission_file),
        )
        .route(
            "/api/missions/{mission_id}/migrate-workflow",
            post(super::migrate_workflow_to_mission),
        )
        .route(
            "/api/missions/{mission_id}/settings",
            put(super::update_mission_settings),
        )
        .route(
            "/api/missions/{mission_id}/default-template",
            get(super::get_default_template),
        )
        .route(
            "/api/missions/{mission_id}/start-orchestrator",
            post(super::start_mission_orchestrator_endpoint),
        )
        .route(
            "/api/missions/{mission_id}/dispatch",
            post(super::dispatch_mission_issue),
        )
        .route(
            "/api/server/linear-key",
            get(super::check_linear_key)
                .post(super::set_linear_key)
                .delete(super::delete_linear_key),
        )
        .route("/api/server/tracker-keys", get(super::get_tracker_keys))
        .route(
            "/api/server/mission-defaults",
            get(super::get_mission_defaults).put(super::update_mission_defaults),
        )
}
