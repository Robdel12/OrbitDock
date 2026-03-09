# OrbitDock Server API

Last updated: 2026-03-09

This doc is the route-level contract for OrbitDock's server. It covers every current HTTP endpoint plus the WebSocket entrypoint.

It was audited against:

- `orbitdock-server/crates/server/src/app/mod.rs`
- `orbitdock-server/crates/server/src/transport/http/router.rs`
- `OrbitDock/OrbitDock/Services/Server/APIClient.swift`

For architecture, ownership, and implementation details, see `docs/server-architecture.md`.

## Transport Rules

- Use HTTP REST for reads, mutations, and fire-and-forget actions.
- Use WebSocket (`/ws`) for subscriptions, real-time session interaction, and server-pushed events.
- New clients should default to REST. Use WebSocket when the operation needs the persistent connection.
- REST mutations often still produce WebSocket broadcasts so other clients stay in sync.

Legacy WebSocket request/response helpers that now map to REST-only routes return:

```json
{
  "type": "error",
  "code": "http_only_endpoint",
  "message": "Use REST endpoint GET /api/... for this request"
}
```

## Auth

When auth is configured, all routes except `GET /health` require:

```http
Authorization: Bearer <token>
```

## Common Response Shapes

Fire-and-forget endpoints usually return:

```json
{"accepted": true}
```

HTTP API errors use:

```json
{
  "code": "string_code",
  "error": "human message"
}
```

## HTTP Endpoints

### Core

#### `GET /health`

Response:

```json
{"status":"ok"}
```

#### `GET /metrics`

Returns Prometheus-style metrics text.

#### `POST /api/hook`

Internal hook ingestion endpoint used by `orbitdock hook-forward <type>`.

Request:

- JSON hook payload
- Includes the injected `type` field (`claude_session_start`, `claude_status_event`, `claude_tool_event`, and so on)

Response:

- `200 OK` with a JSON acknowledgement payload

Notes:

- This is for Claude hook forwarding, not normal client traffic.

### Sessions: Read

#### `GET /api/sessions`

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

#### `GET /api/sessions/{session_id}`

Returns full session state.

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

Error responses:

- `404 not_found`
- `500 db_error`
- `503 runtime_error`

#### `GET /api/sessions/{session_id}/conversation?limit=<n>`

Returns the bootstrap payload for a conversation view.

Query params:

- `limit` optional, clamped to `1...200`, default `50`

Response:

```json
{
  "session": {
    "id": "od-..."
  },
  "total_message_count": 120,
  "has_more_before": true,
  "oldest_sequence": 71,
  "newest_sequence": 120
}
```

Error responses:

- `404 not_found`
- `500 db_error`
- `503 runtime_error`

#### `GET /api/sessions/{session_id}/messages?before_sequence=<seq>&limit=<n>`

Returns a paged slice of older conversation messages.

Query params:

- `before_sequence` optional
- `limit` optional, clamped to `1...200`, default `50`

Response:

```json
{
  "session_id": "od-...",
  "messages": [],
  "total_message_count": 120,
  "has_more_before": true,
  "oldest_sequence": 21,
  "newest_sequence": 70
}
```

Error responses:

- `404 not_found`
- `500 db_error`
- `503 runtime_error`

#### `POST /api/sessions/{session_id}/mark-read`

Marks the session as read and persists the latest read position.

Response:

```json
{
  "session_id": "od-...",
  "unread_count": 0
}
```

Error responses:

- `404 session_not_found`

### Sessions: Lifecycle

#### `POST /api/sessions`

Creates a direct session and returns the new summary immediately.

Request:

```json
{
  "provider": "codex",
  "cwd": "/Users/.../repo",
  "model": "gpt-5",
  "approval_policy": "on-request",
  "sandbox_mode": "workspace-write",
  "permission_mode": "default",
  "allowed_tools": [],
  "disallowed_tools": [],
  "effort": "medium"
}
```

Response:

```json
{
  "session_id": "od-...",
  "session": {
    "id": "od-..."
  }
}
```

Notes:

- The server persists first, then tries to launch the connector.
- `session_created` is broadcast to list subscribers over WebSocket.

#### `POST /api/sessions/{session_id}/resume`

Resumes a persisted session.

Response:

```json
{
  "session_id": "od-...",
  "session": {
    "id": "od-..."
  }
}
```

Error responses:

- `404 session_not_found`
- `409 already_active`
- `422 missing_claude_resume_id`
- `500 db_error`

#### `POST /api/sessions/{session_id}/takeover`

Takes over a passive session.

Request:

```json
{
  "model": "gpt-5",
  "approval_policy": "on-request",
  "sandbox_mode": "workspace-write",
  "permission_mode": "default",
  "allowed_tools": [],
  "disallowed_tools": []
}
```

Response:

```json
{
  "session_id": "od-...",
  "accepted": true
}
```

Error responses:

- `404 not_found`
- `409 not_passive`
- `500 take_handle_failed`
- `500 connector_failed`

#### `POST /api/sessions/{session_id}/end`

Ends the session.

Response:

```json
{"accepted": true}
```

#### `PATCH /api/sessions/{session_id}/name`

Sets or clears a custom session name.

Request:

```json
{
  "name": "Investigate approval drift"
}
```

Request to clear:

```json
{
  "name": null
}
```

Response:

```json
{"accepted": true}
```

Error responses:

- `404 not_found`

#### `PATCH /api/sessions/{session_id}/config`

Updates stored session config.

Request:

```json
{
  "approval_policy": "on-request",
  "sandbox_mode": "workspace-write",
  "permission_mode": "default"
}
```

All fields are optional.

Response:

```json
{"accepted": true}
```

Error responses:

- `404 not_found`

#### `POST /api/sessions/{session_id}/fork`

Forks a session.

Request:

```json
{
  "nth_user_message": 3,
  "model": "gpt-5",
  "approval_policy": "on-request",
  "sandbox_mode": "workspace-write",
  "cwd": "/Users/.../repo",
  "permission_mode": "default",
  "allowed_tools": [],
  "disallowed_tools": []
}
```

All fields are optional.

Response:

```json
{
  "source_session_id": "od-source",
  "new_session_id": "od-fork",
  "session": {
    "id": "od-fork"
  }
}
```

Error responses:

- `404 session_not_found`
- `422 not_found` when the source Codex connector is not active
- `500 fork_failed`
- `500 channel_closed`

#### `POST /api/sessions/{session_id}/fork-to-worktree`

Creates a worktree, then forks into it.

Request:

```json
{
  "branch_name": "feature/api-doc-pass",
  "base_branch": "main",
  "nth_user_message": 3
}
```

Response:

```json
{
  "source_session_id": "od-source",
  "new_session_id": "od-fork",
  "session": {
    "id": "od-fork"
  },
  "worktree": {
    "id": "wt-..."
  }
}
```

Error responses:

- `404 session_not_found`
- `400 worktree_create_invalid_input`
- `500 worktree_create_failed`
- Plus the same fork errors as `POST /fork`

#### `POST /api/sessions/{session_id}/fork-to-existing-worktree`

Forks into an existing tracked worktree.

Request:

```json
{
  "worktree_id": "wt-...",
  "nth_user_message": 3
}
```

Response:

```json
{
  "source_session_id": "od-source",
  "new_session_id": "od-fork",
  "session": {
    "id": "od-fork"
  }
}
```

Error responses:

- `400 worktree_repo_mismatch`
- `404 worktree_not_found`
- `410 worktree_missing`
- Plus the same fork errors as `POST /fork`

### Sessions: Messaging And Actions

#### `POST /api/sessions/{session_id}/messages`

Queues a new user turn.

Request:

```json
{
  "content": "Review the approval flow",
  "model": "gpt-5",
  "effort": "medium",
  "skills": [],
  "images": [],
  "mentions": []
}
```

At least one of `content`, `images`, `mentions`, or `skills` is required.

Response:

```json
{"accepted": true}
```

Error responses:

- `400 invalid_request`
- Session/dispatch errors from the active connector

#### `POST /api/sessions/{session_id}/steer`

Steers the active turn without creating a normal user turn.

Request:

```json
{
  "content": "Focus on REST-only routes",
  "images": [],
  "mentions": []
}
```

At least one of `content`, `images`, or `mentions` is required.

Response:

```json
{"accepted": true}
```

Error responses:

- `400 invalid_request`
- Session/dispatch errors from the active connector

#### `POST /api/sessions/{session_id}/interrupt`

Interrupts the active turn.

Response:

```json
{"accepted": true}
```

#### `POST /api/sessions/{session_id}/compact`

Requests context compaction.

Response:

```json
{"accepted": true}
```

#### `POST /api/sessions/{session_id}/undo`

Undoes the last turn.

Response:

```json
{"accepted": true}
```

#### `POST /api/sessions/{session_id}/rollback`

Rolls back the last `n` turns.

Request:

```json
{
  "num_turns": 2
}
```

Response:

```json
{"accepted": true}
```

Error responses:

- `400 invalid_argument` when `num_turns < 1`

#### `POST /api/sessions/{session_id}/stop-task`

Stops a running task by task id.

Request:

```json
{
  "task_id": "task-..."
}
```

Response:

```json
{"accepted": true}
```

#### `POST /api/sessions/{session_id}/rewind-files`

Rewinds files to the state associated with a user message.

Request:

```json
{
  "user_message_id": "msg-..."
}
```

Response:

```json
{"accepted": true}
```

### Approvals

#### `GET /api/approvals?session_id=<id>&limit=<n>`

Query params:

- `session_id` optional
- `limit` optional

Response:

```json
{
  "session_id": "od-...",
  "approvals": []
}
```

Error responses:

- `500 approval_list_failed`

#### `DELETE /api/approvals/{approval_id}`

Response:

```json
{
  "approval_id": 42,
  "deleted": true
}
```

Error responses:

- `404 not_found`
- `500 approval_delete_failed`

#### `POST /api/sessions/{session_id}/approve`

Approves or denies a tool request.

Request:

```json
{
  "request_id": "req-...",
  "decision": "approved",
  "message": "Looks good",
  "interrupt": false,
  "updated_input": {
    "path": "src/main.rs"
  }
}
```

Only `request_id` and `decision` are required.

Response:

```json
{
  "session_id": "od-...",
  "request_id": "req-...",
  "outcome": "approved",
  "active_request_id": null,
  "approval_version": 9
}
```

Error responses:

- `404 not_found`
- `400 invalid_answer_payload`
- `422 rollback_failed`
- `500` for other dispatch failures

#### `POST /api/sessions/{session_id}/answer`

Answers a question approval.

Request:

```json
{
  "request_id": "req-...",
  "answer": "Use the REST route",
  "question_id": "question-1",
  "answers": {
    "selection": ["rest"]
  }
}
```

`answer`, `question_id`, and `answers` are optional individually, but the overall payload must still be meaningful to the active connector.

Response:

```json
{
  "session_id": "od-...",
  "request_id": "req-...",
  "outcome": "answered",
  "active_request_id": null,
  "approval_version": 10
}
```

Error responses:

- `404 not_found`
- `400 invalid_answer_payload`
- `422 rollback_failed`
- `500` for other dispatch failures

### Attachments And Shell

#### `POST /api/sessions/{session_id}/attachments/images?display_name=<name>&pixel_width=<w>&pixel_height=<h>`

Uploads an image attachment.

Request:

- Raw image bytes in the request body
- `Content-Type` header is required and should be the image MIME type

Query params:

- `display_name` optional
- `pixel_width` optional
- `pixel_height` optional

Response:

```json
{
  "image": {
    "input_type": "attachment",
    "value": "attachment-...",
    "mime_type": "image/png"
  }
}
```

Error responses:

- `404 not_found`
- `400 invalid_request` if bytes or content type are missing
- `500 attachment_store_failed`

#### `GET /api/sessions/{session_id}/attachments/images/{attachment_id}`

Returns the raw image bytes.

Response:

- Binary body
- `Content-Type: <stored mime type>`

Error responses:

- `404 attachment_read_failed`
- `500 attachment_read_failed`

#### `POST /api/sessions/{session_id}/shell/exec`

Starts a shell command in the context of the session.

Request:

```json
{
  "command": "git status",
  "cwd": "/Users/.../repo",
  "timeout_secs": 120
}
```

`cwd` and `timeout_secs` are optional. If `cwd` is omitted, the server uses the session's current cwd, then falls back to the project path.

Response:

```json
{
  "request_id": "shell-...",
  "accepted": true
}
```

Notes:

- Streaming shell output is delivered through WebSocket events and message updates.

Error responses:

- `404 session_not_found`
- `409 shell_duplicate_request_id`

#### `POST /api/sessions/{session_id}/shell/cancel`

Cancels an active shell request.

Request:

```json
{
  "request_id": "shell-..."
}
```

Response:

```json
{"accepted": true}
```

Error responses:

- `404 session_not_found`
- `404 shell_request_not_found`

### Skills, MCP, Flags, And Permissions

#### `GET /api/sessions/{session_id}/subagents/{subagent_id}/tools`

Response:

```json
{
  "session_id": "od-...",
  "subagent_id": "subagent-...",
  "tools": []
}
```

Notes:

- If the subagent transcript is missing or unreadable, this returns an empty list.

#### `GET /api/sessions/{session_id}/skills?cwd=<path>&force_reload=true|false`

Returns skills grouped by cwd.

Query params:

- `cwd` optional and repeatable
- `force_reload` optional, default `false`

Response:

```json
{
  "session_id": "od-...",
  "skills": [],
  "errors": []
}
```

Error responses:

- `409 session_not_found`
- Connector-specific MCP/skills startup errors surfaced through the dispatched action

#### `GET /api/sessions/{session_id}/skills/remote`

Returns remote skills available to the session.

Response:

```json
{
  "session_id": "od-...",
  "skills": []
}
```

Error responses:

- `409 session_not_found`

#### `POST /api/sessions/{session_id}/skills/download`

Queues a remote skill download.

Request:

```json
{
  "hazelnut_id": "hz-..."
}
```

Response:

```json
{"accepted": true}
```

Notes:

- Returns `202 Accepted`.
- Completion is delivered through WebSocket (`remote_skill_downloaded`).

#### `GET /api/sessions/{session_id}/mcp/tools`

Returns the current MCP tool catalog.

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

Error responses:

- `409 session_not_found`

Notes:

- Codex sessions dispatch `ListMcpTools` first.
- If that is unavailable, the server falls back to the Claude MCP route.

#### `POST /api/sessions/{session_id}/mcp/refresh`

Refreshes MCP servers.

Request:

```json
{
  "server_name": "github"
}
```

Request body is optional. Without it, the server refreshes the overall MCP state.

Response:

```json
{"accepted": true}
```

Notes:

- Returns `202 Accepted`.

#### `POST /api/sessions/{session_id}/mcp/toggle`

Enables or disables a Claude MCP server.

Request:

```json
{
  "server_name": "github",
  "enabled": true
}
```

Response:

```json
{"accepted": true}
```

Notes:

- Returns `202 Accepted`.

#### `POST /api/sessions/{session_id}/mcp/authenticate`

Starts auth for a Claude MCP server.

Request:

```json
{
  "server_name": "github"
}
```

Response:

```json
{"accepted": true}
```

Notes:

- Returns `202 Accepted`.

#### `POST /api/sessions/{session_id}/mcp/clear-auth`

Clears saved auth for a Claude MCP server.

Request:

```json
{
  "server_name": "github"
}
```

Response:

```json
{"accepted": true}
```

Notes:

- Returns `202 Accepted`.

#### `POST /api/sessions/{session_id}/mcp/servers`

Applies Claude MCP server config.

Request:

```json
{
  "servers": {
    "github": {
      "enabled": true
    }
  }
}
```

Response:

```json
{"accepted": true}
```

Notes:

- Returns `202 Accepted`.

#### `POST /api/sessions/{session_id}/flags`

Applies Claude flag settings.

Request:

```json
{
  "settings": {
    "enablePlanner": true
  }
}
```

Response:

```json
{"accepted": true}
```

Notes:

- Returns `202 Accepted`.

#### `GET /api/sessions/{session_id}/permissions`

Returns the effective permission rules for the active session.

Response for Claude:

```json
{
  "session_id": "od-...",
  "rules": {
    "provider": "claude",
    "rules": []
  }
}
```

Response for Codex:

```json
{
  "session_id": "od-...",
  "rules": {
    "provider": "codex",
    "approval_policy": "on-request",
    "sandbox_mode": "workspace-write"
  }
}
```

Error responses:

- `404 not_found`

Notes:

- Claude first tries `get_settings` from the running CLI, then falls back to on-disk settings.

#### `POST /api/sessions/{session_id}/permissions/rules`

Adds a Claude permission rule.

Request:

```json
{
  "pattern": "Bash(git status:*)",
  "behavior": "allow",
  "scope": "project"
}
```

`scope` defaults to `project`. Use `global` to write to `~/.claude/settings.local.json`.

Response:

```json
{"ok": true}
```

Error responses:

- `404 not_found`
- `500 serialize_error`
- `500 write_error`

#### `DELETE /api/sessions/{session_id}/permissions/rules`

Removes a Claude permission rule.

Request body matches the add route.

Response:

```json
{"ok": true}
```

Error responses:

- `404 not_found`
- `500 serialize_error`
- `500 write_error`

### Review Comments

#### `GET /api/sessions/{session_id}/review-comments?turn_id=<turn-id>`

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

- If loading fails, this returns an empty list.

#### `POST /api/sessions/{session_id}/review-comments`

Creates a review comment.

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

`turn_id`, `line_end`, and `tag` are optional.

Response:

```json
{
  "comment_id": "rc-...",
  "ok": true
}
```

Notes:

- Server broadcasts `review_comment_created` to session subscribers over WebSocket.

#### `PATCH /api/review-comments/{comment_id}`

Updates a review comment.

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

Error responses:

- `404 not_found`
- `500 review_comment_update_failed`

#### `DELETE /api/review-comments/{comment_id}`

Deletes a review comment.

Response:

```json
{
  "comment_id": "rc-...",
  "ok": true
}
```

Error responses:

- `404 not_found`
- `500 review_comment_delete_failed`

### Server Info, Auth, And Metadata

#### `GET /api/server/openai-key`

Response:

```json
{"configured": true}
```

#### `POST /api/server/openai-key`

Stores the OpenAI API key.

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

#### `PUT /api/server/role`

Sets whether this server is primary.

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

- Broadcasts a `server_info` update to connected WebSocket clients.

#### `POST /api/client/primary-claim`

Registers or clears a client's primary claim.

Request:

```json
{
  "client_id": "client-...",
  "device_name": "Robert's MacBook Pro",
  "is_primary": true
}
```

Response:

```json
{"accepted": true}
```

Notes:

- Broadcasts a `server_info` update to connected WebSocket clients.

#### `GET /api/usage/codex`

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

#### `GET /api/usage/claude`

Same response shape as Codex usage.

#### `GET /api/models/codex`

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
      "supported_reasoning_efforts": ["low", "medium", "high"],
      "supports_reasoning_summaries": true
    }
  ]
}
```

#### `GET /api/models/claude`

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

#### `GET /api/codex/account?refresh_token=true|false`

Returns current Codex auth/account state.

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

Error responses:

- `503 codex_auth_error`

#### `POST /api/codex/login/start`

Starts the ChatGPT browser login flow.

Response:

```json
{
  "login_id": "...",
  "auth_url": "https://..."
}
```

Error responses:

- `500 codex_auth_login_start_failed`

Notes:

- If account state is available, the server broadcasts it over WebSocket right after starting login.

#### `POST /api/codex/login/cancel`

Cancels an in-progress login.

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

Status values:

- `canceled`
- `not_found`
- `invalid_id`

Notes:

- The server broadcasts refreshed account status when available.

#### `POST /api/codex/logout`

Logs out the current Codex account.

Response:

```json
{
  "status": { }
}
```

Error responses:

- `500 codex_auth_logout_failed`

Notes:

- Broadcasts `codex_account_updated` to connected WebSocket clients.

### Filesystem And Git

#### `POST /api/git/init`

Runs `git init` in the target directory.

Request:

```json
{
  "path": "/Users/.../new-project"
}
```

Response:

```json
{"ok": true}
```

Error responses:

- `400 path_not_found`
- `400 git_init_failed`

#### `GET /api/fs/browse?path=<absolute-or-tilde-path>`

Lists directory entries.

Query params:

- `path` optional, defaults to the user's home directory

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

- Hidden entries are omitted.
- Results are sorted with directories first, then case-insensitive name.
- `~` is expanded to the current home directory.
- Read failures return an empty `entries` list instead of an error.

#### `GET /api/fs/recent-projects`

Returns recently active project roots.

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

### Worktrees

#### `GET /api/worktrees?repo_root=<path>`

Returns tracked or discovered worktrees for a repo root.

Query params:

- `repo_root` optional

Response:

```json
{
  "repo_root": "/path/to/repo",
  "worktree_revision": 12,
  "worktrees": []
}
```

Notes:

- Without `repo_root`, this currently returns an empty list.
- If the database has no tracked rows for the repo, the server falls back to `git worktree list` discovery.

#### `POST /api/worktrees`

Creates a tracked worktree.

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
  "repo_root": "/path/to/repo",
  "worktree_revision": 13,
  "worktree": {
    "id": "wt-...",
    "repo_root": "/path/to/repo",
    "worktree_path": "/path/to/repo/.orbitdock-worktrees/feature-x",
    "branch": "feature-x",
    "status": "active"
  }
}
```

Error responses:

- `400 create_failed`

Notes:

- Broadcasts `worktree_created` to list subscribers over WebSocket.
- If `repo_path/.worktreeinclude` exists, OrbitDock tries to copy matching local ignored files into the new worktree.

#### `POST /api/worktrees/discover`

Discovers worktrees for a repo path without requiring tracked DB rows.

Request:

```json
{
  "repo_path": "/path/to/repo"
}
```

Response:

```json
{
  "repo_root": "/path/to/repo",
  "worktree_revision": 12,
  "worktrees": []
}
```

#### `DELETE /api/worktrees/{worktree_id}?force=true|false&delete_branch=true|false&delete_remote_branch=true|false&archive_only=true|false`

Removes or archives a tracked worktree.

Query params:

- `force` optional, default `false`
- `delete_branch` optional, default `false`
- `delete_remote_branch` optional, default `false`
- `archive_only` optional, default `false`

Response:

```json
{
  "repo_root": "/path/to/repo",
  "worktree_revision": 14,
  "worktree_id": "wt-...",
  "deleted": true,
  "ok": true
}
```

Error responses:

- `404 not_found`
- `400 remove_failed`

Notes:

- `force=true` keeps going even if `git worktree remove` fails.
- `archive_only=true` skips on-disk deletion and only updates tracked state.
- Broadcasts `worktree_removed` to list subscribers over WebSocket.

## WebSocket Endpoint

### `GET /ws`

WebSocket is used for:

- session and list subscriptions
- real-time turn interaction
- server-pushed updates
- approval prompts and results
- shell streaming updates
- worktree, review comment, and auth status broadcasts

Common client messages include:

- `subscribe_list`
- `subscribe_session`
- `unsubscribe_session`
- `create_session`
- `resume_session`
- `send_message`
- `approve_tool`
- `answer_question`
- `interrupt_session`

`subscribe_session` supports:

- `since_revision` optional
- `include_snapshot` optional, default `true`

Example:

```json
{
  "type": "subscribe_session",
  "session_id": "od-...",
  "since_revision": 120,
  "include_snapshot": false
}
```

When `include_snapshot=false`, the server skips the initial snapshot and only streams replayed or live incremental events.
