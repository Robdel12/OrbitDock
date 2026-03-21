use orbitdock_protocol::ClientMessage;

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct RestOnlyRoute {
    pub endpoint: &'static str,
    pub session_id: Option<String>,
}

pub(crate) fn rest_only_route(message: &ClientMessage) -> Option<RestOnlyRoute> {
    match message {
        ClientMessage::BrowseDirectory { .. } => Some(route("GET /api/fs/browse", None)),
        ClientMessage::ListRecentProjects { .. } => {
            Some(route("GET /api/fs/recent-projects", None))
        }
        ClientMessage::CheckOpenAiKey { .. } => Some(route("GET /api/server/openai-key", None)),
        ClientMessage::ListModels => Some(route("GET /api/models/codex", None)),
        ClientMessage::FetchCodexUsage { .. } => Some(route("GET /api/usage/codex", None)),
        ClientMessage::FetchClaudeUsage { .. } => Some(route("GET /api/usage/claude", None)),
        ClientMessage::SetOpenAiKey { .. } => Some(route("POST /api/server/openai-key", None)),
        ClientMessage::SetServerRole { .. } => Some(route("PUT /api/server/role", None)),
        ClientMessage::ListWorktrees { repo_root, .. } => {
            Some(route("GET /api/worktrees?repo_root=...", repo_root.clone()))
        }
        ClientMessage::CreateWorktree { .. } => Some(route("POST /api/worktrees", None)),
        ClientMessage::RemoveWorktree { .. } => {
            Some(route("DELETE /api/worktrees/{worktree_id}", None))
        }
        ClientMessage::DiscoverWorktrees { .. } => {
            Some(route("POST /api/worktrees/discover", None))
        }
        ClientMessage::ListReviewComments { session_id, .. } => Some(route(
            "GET /api/sessions/{session_id}/review-comments",
            Some(session_id.clone()),
        )),
        ClientMessage::CreateReviewComment { session_id, .. } => Some(route(
            "POST /api/sessions/{session_id}/review-comments",
            Some(session_id.clone()),
        )),
        ClientMessage::UpdateReviewComment { comment_id, .. } => Some(route(
            "PATCH /api/review-comments/{comment_id}",
            Some(comment_id.clone()),
        )),
        ClientMessage::DeleteReviewComment { comment_id } => Some(route(
            "DELETE /api/review-comments/{comment_id}",
            Some(comment_id.clone()),
        )),
        ClientMessage::CodexAccountRead { .. } => Some(route("GET /api/codex/account", None)),
        ClientMessage::CodexLoginChatgptStart => Some(route("POST /api/codex/login/start", None)),
        ClientMessage::CodexLoginChatgptCancel { .. } => {
            Some(route("POST /api/codex/login/cancel", None))
        }
        ClientMessage::CodexAccountLogout => Some(route("POST /api/codex/logout", None)),
        ClientMessage::ListSkills { session_id, .. } => Some(route(
            "GET /api/sessions/{session_id}/skills",
            Some(session_id.clone()),
        )),
        ClientMessage::ListRemoteSkills { session_id } => Some(route(
            "GET /api/sessions/{session_id}/skills/remote",
            Some(session_id.clone()),
        )),
        ClientMessage::DownloadRemoteSkill { session_id, .. } => Some(route(
            "POST /api/sessions/{session_id}/skills/download",
            Some(session_id.clone()),
        )),
        ClientMessage::ListMcpTools { session_id } => Some(route(
            "GET /api/sessions/{session_id}/mcp/tools",
            Some(session_id.clone()),
        )),
        ClientMessage::RefreshMcpServers { session_id } => Some(route(
            "POST /api/sessions/{session_id}/mcp/refresh",
            Some(session_id.clone()),
        )),
        _ => None,
    }
}

fn route(endpoint: &'static str, session_id: Option<String>) -> RestOnlyRoute {
    RestOnlyRoute {
        endpoint,
        session_id,
    }
}
