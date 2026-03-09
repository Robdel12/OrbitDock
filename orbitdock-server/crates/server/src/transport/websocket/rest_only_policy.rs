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
        ClientMessage::ListClaudeModels => Some(route("GET /api/models/claude", None)),
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

#[cfg(test)]
mod tests {
    use super::{rest_only_route, RestOnlyRoute};
    use orbitdock_protocol::ClientMessage;

    #[test]
    fn maps_config_messages_to_rest_endpoints() {
        assert_eq!(
            rest_only_route(&ClientMessage::CheckOpenAiKey {
                request_id: "req-1".to_string(),
            }),
            Some(RestOnlyRoute {
                endpoint: "GET /api/server/openai-key",
                session_id: None,
            })
        );
        assert_eq!(
            rest_only_route(&ClientMessage::SetServerRole { is_primary: true }),
            Some(RestOnlyRoute {
                endpoint: "PUT /api/server/role",
                session_id: None,
            })
        );
    }

    #[test]
    fn maps_session_scoped_messages_with_authoritative_ids() {
        assert_eq!(
            rest_only_route(&ClientMessage::ListSkills {
                session_id: "session-1".to_string(),
                cwds: vec![],
                force_reload: false,
            }),
            Some(RestOnlyRoute {
                endpoint: "GET /api/sessions/{session_id}/skills",
                session_id: Some("session-1".to_string()),
            })
        );
        assert_eq!(
            rest_only_route(&ClientMessage::UpdateReviewComment {
                comment_id: "comment-1".to_string(),
                body: Some("updated".to_string()),
                tag: None,
                status: None,
            }),
            Some(RestOnlyRoute {
                endpoint: "PATCH /api/review-comments/{comment_id}",
                session_id: Some("comment-1".to_string()),
            })
        );
    }

    #[test]
    fn ignores_live_websocket_messages() {
        assert_eq!(
            rest_only_route(&ClientMessage::ResumeSession {
                session_id: "session-1".to_string(),
            }),
            None
        );
        assert_eq!(
            rest_only_route(&ClientMessage::ForkSession {
                source_session_id: "session-1".to_string(),
                nth_user_message: None,
                cwd: None,
                model: None,
                approval_policy: None,
                sandbox_mode: None,
                permission_mode: None,
                allowed_tools: vec![],
                disallowed_tools: vec![],
            }),
            None
        );
    }
}
