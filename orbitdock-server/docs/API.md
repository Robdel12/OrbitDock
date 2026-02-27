# OrbitDock Server API

This file is intentionally narrow: routes, payloads, and transport rules.

## Transport Rules

- Use **HTTP REST** for reads, mutations, and fire-and-forget actions.
- Use **WebSocket (`/ws`)** for subscriptions, real-time session interaction (create, send, approve, interrupt), and server-pushed events.
- New clients should default to REST. Only use WS for operations that need the persistent connection.
- Legacy WS request/response utilities now return:

```json
{
  "type": "error",
  "code": "http_only_endpoint",
  "message": "Use REST endpoint GET /api/... for this request"
}
```

Affected WS requests include all read/utility requests (`check_openai_key`, `fetch_codex_usage`,
`fetch_claude_usage`, `browse_directory`, `list_recent_projects`, `list_approvals`,
`delete_approval`, `list_models`, `list_claude_models`, `codex_account_read`,
`list_review_comments`, `get_subagent_tools`, `list_skills`, `list_remote_skills`,
`list_mcp_tools`) and all mutation requests (`set_openai_key`, `set_server_role`,
`list_worktrees`, `create_worktree`, `remove_worktree`, `discover_worktrees`,
`create_review_comment`, `update_review_comment`, `delete_review_comment`,
`codex_login_chatgpt_start`, `codex_login_chatgpt_cancel`, `codex_account_logout`,
`download_remote_skill`, `refresh_mcp_servers`).

## Auth

When server starts with `--auth-token`, all routes except `/health` require:

- `Authorization: Bearer <token>`

For WebSocket only, `?token=<token>` is also accepted.

## HTTP Endpoints

### `GET /health`

Response:

```json
{"status":"ok"}
```

### `GET /api/sessions`

Returns session summaries.

Response:

```json
{
  "sessions": [
    {
      "id": "od-...",
      "provider": "codex",
      "project_path": "/Users/.../repo",
      "status": "active",
      "work_status": "waiting"
    }
  ]
}
```

### `GET /api/sessions/{session_id}`

Returns full session state (messages, token usage, approvals metadata, diffs, etc).

Response:

```json
{
  "session": {
    "id": "od-...",
    "provider": "codex",
    "messages": [],
    "revision": 123
  }
}
```

### `GET /api/approvals?session_id=<id>&limit=<n>`

Query params:

- `session_id` optional
- `limit` optional (server caps to 1000)

Response:

```json
{
  "session_id": "od-...",
  "approvals": []
}
```

### `DELETE /api/approvals/{approval_id}`

Response:

```json
{
  "approval_id": 42,
  "deleted": true
}
```

404 response:

```json
{
  "code": "not_found",
  "error": "Approval 42 not found"
}
```

### `GET /api/server/openai-key`

Response:

```json
{"configured":true}
```

### `GET /api/usage/codex`

Response:

```json
{
  "usage": null,
  "error_info": {
    "code": "not_control_plane_endpoint",
    "message": "This endpoint is not primary for control-plane usage reads."
  }
}
```

### `GET /api/usage/claude`

Response shape is the same as codex usage.

### `GET /api/models/codex`

Returns discovered Codex models.

Response:

```json
{
  "models": [
    {
      "id": "gpt-5",
      "model": "gpt-5",
      "display_name": "GPT-5",
      "description": "General-purpose coding model",
      "is_default": true,
      "supported_reasoning_efforts": ["low", "medium", "high"]
    }
  ]
}
```

### `GET /api/models/claude`

Returns cached Claude models from local persistence.

Response:

```json
{
  "models": [
    {
      "value": "claude-sonnet-4-5",
      "display_name": "Claude Sonnet 4.5",
      "description": "Balanced speed and quality"
    }
  ]
}
```

### `GET /api/codex/account?refresh_token=true|false`

Query params:

- `refresh_token` optional, default `false`

Response:

```json
{
  "status": {
    "auth_mode": "chatgpt",
    "requires_openai_auth": true,
    "account": {
      "type": "chatgpt",
      "email": "user@example.com",
      "plan_type": "plus"
    },
    "login_in_progress": false
  }
}
```

Error response example (`503`):

```json
{
  "code": "codex_auth_error",
  "error": "Failed to find codex home: ..."
}
```

### `GET /api/sessions/{session_id}/review-comments?turn_id=<turn-id>`

Query params:

- `turn_id` optional

Response:

```json
{
  "session_id": "od-...",
  "comments": []
}
```

Notes:

- If comment loading fails, this endpoint returns an empty list.

### `GET /api/sessions/{session_id}/subagents/{subagent_id}/tools`

Response:

```json
{
  "session_id": "od-...",
  "subagent_id": "subagent-...",
  "tools": []
}
```

Notes:

- If the subagent transcript is missing or unreadable, this endpoint returns an empty list.

### `GET /api/sessions/{session_id}/skills?cwd=<path>&force_reload=true|false`

Returns session skills grouped by cwd.

Query params:

- `cwd` optional, repeatable
- `force_reload` optional, default `false`

Response:

```json
{
  "session_id": "od-...",
  "skills": [],
  "errors": []
}
```

Error response example (`409`):

```json
{
  "code": "session_not_found",
  "error": "Session od-... not found or has no active connector"
}
```

Notes:

- `409` here is a connector availability state (for example, lazy connector startup), not an MCP auth failure.

### `GET /api/sessions/{session_id}/skills/remote`

Returns remote skills available for the session.

Response:

```json
{
  "session_id": "od-...",
  "skills": []
}
```

Error response example (`409`):

```json
{
  "code": "session_not_found",
  "error": "Session od-... not found or has no active connector"
}
```

### `GET /api/sessions/{session_id}/mcp/tools`

Returns MCP tools/resources/auth status for the session.

Response:

```json
{
  "session_id": "od-...",
  "tools": {},
  "resources": {},
  "resource_templates": {},
  "auth_statuses": {}
}
```

Error response example (`409`):

```json
{
  "code": "session_not_found",
  "error": "Session od-... not found or has no active connector"
}
```

Notes:

- Real MCP server failures (auth/startup/tool discovery) are surfaced through MCP startup/status events, not by this connector-availability response.

### `GET /api/fs/recent-projects`

Response:

```json
{
  "projects": [
    {
      "path": "/Users/.../repo",
      "session_count": 3,
      "last_active": "1735689600Z"
    }
  ]
}
```

### `GET /api/fs/browse?path=<absolute-or-tilde-path>`

Query params:

- `path` optional, defaults to home directory

Response:

```json
{
  "path": "/Users/.../repo",
  "entries": [
    {
      "name": "src",
      "is_dir": true,
      "is_git": false
    }
  ]
}
```

Notes:

- Hidden entries (`.` prefix) are omitted.
- Results are sorted with directories first, then case-insensitive name.

### `POST /api/server/openai-key`

Request:

```json
{
  "key": "sk-..."
}
```

Response:

```json
{"configured": true}
```

### `PUT /api/server/role`

Request:

```json
{
  "is_primary": true
}
```

Response:

```json
{"is_primary": true}
```

Notes:

- Server broadcasts `server_info` to all WS clients after the role change.

### `GET /api/worktrees?repo_root=<path>`

Query params:

- `repo_root` optional

Response:

```json
{
  "repo_root": "/path/to/repo",
  "worktrees": []
}
```

### `POST /api/worktrees`

Request:

```json
{
  "repo_path": "/path/to/repo",
  "branch_name": "feature-x",
  "base_branch": "main"
}
```

Response:

```json
{
  "worktree": {
    "id": "...",
    "repo_root": "/path/to/repo",
    "worktree_path": "/path/to/repo/.orbitdock-worktrees/feature-x",
    "branch": "feature-x",
    "status": "active"
  }
}
```

### `POST /api/worktrees/discover`

Request:

```json
{
  "repo_path": "/path/to/repo"
}
```

Response: same shape as `GET /api/worktrees`.

### `DELETE /api/worktrees/{worktree_id}`

Currently returns `404` (persistence pending).

### `POST /api/sessions/{session_id}/review-comments`

Request:

```json
{
  "turn_id": "turn-...",
  "file_path": "src/main.rs",
  "line_start": 42,
  "line_end": 45,
  "body": "This needs error handling",
  "tag": "risk"
}
```

Response:

```json
{
  "comment_id": "rc-...",
  "ok": true
}
```

Notes:

- Server broadcasts `review_comment_created` to session subscribers via WS.

### `PATCH /api/review-comments/{comment_id}`

Request:

```json
{
  "body": "Updated text",
  "tag": "nit",
  "status": "resolved"
}
```

All fields are optional.

Response:

```json
{
  "comment_id": "rc-...",
  "ok": true
}
```

### `DELETE /api/review-comments/{comment_id}`

Response:

```json
{
  "comment_id": "rc-...",
  "ok": true
}
```

### `POST /api/codex/login/start`

Starts the ChatGPT browser login flow.

Response:

```json
{
  "login_id": "...",
  "auth_url": "https://..."
}
```

### `POST /api/codex/login/cancel`

Request:

```json
{
  "login_id": "..."
}
```

Response:

```json
{
  "login_id": "...",
  "status": "canceled"
}
```

Status values: `canceled`, `not_found`, `invalid_id`.

### `POST /api/codex/logout`

Response:

```json
{
  "status": { ... }
}
```

Notes:

- Server broadcasts `codex_account_updated` to all WS clients.

### `POST /api/sessions/{session_id}/skills/download`

Request:

```json
{
  "hazelnut_id": "..."
}
```

Response (`202 Accepted`):

```json
{"accepted": true}
```

Notes:

- Fire-and-forget. Skill download result is delivered via WS event (`remote_skill_downloaded`).

### `POST /api/sessions/{session_id}/mcp/refresh`

No request body required.

Response (`202 Accepted`):

```json
{"accepted": true}
```

Notes:

- Fire-and-forget. MCP tool updates are delivered via WS events (`mcp_tools_list`, `mcp_startup_update`).

## WebSocket Endpoint

### `GET /ws`

WebSocket is for realtime state updates. Core client messages:

- `subscribe_list`
- `subscribe_session`
- `unsubscribe_session`

`subscribe_session` supports:

- `since_revision` (optional)
- `include_snapshot` (optional, default `true`)

Example:

```json
{
  "type": "subscribe_session",
  "session_id": "od-...",
  "since_revision": 120,
  "include_snapshot": false
}
```

When `include_snapshot=false`, server suppresses initial snapshot and only streams incremental/replay events.

## Error Payload

HTTP API errors use:

```json
{
  "code": "string_code",
  "error": "human message"
}
```
