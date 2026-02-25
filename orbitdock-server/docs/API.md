# OrbitDock Server API

This file is intentionally narrow: routes, payloads, and transport rules.

## Transport Rules

- Use **HTTP REST** for state bootstrap and one-shot reads.
- Use **WebSocket (`/ws`)** for realtime subscription updates and streaming events.
- New clients should prefer HTTP for request/response flows.
- Legacy WS request/response utilities now return:

```json
{
  "type": "error",
  "code": "http_only_endpoint",
  "message": "Use REST endpoint GET /api/... for this request"
}
```

Affected WS requests include `check_openai_key`, `fetch_codex_usage`, `fetch_claude_usage`,
`browse_directory`, `list_recent_projects`, `list_approvals`, `delete_approval`,
`list_models`, `list_claude_models`, `codex_account_read`, `list_review_comments`,
`get_subagent_tools`, `list_skills`, `list_remote_skills`, and `list_mcp_tools`.

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

### `GET /api/sessions/:session_id`

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

### `DELETE /api/approvals/:approval_id`

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

### `GET /api/sessions/:session_id/review-comments?turn_id=<turn-id>`

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

### `GET /api/sessions/:session_id/subagents/:subagent_id/tools`

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

### `GET /api/sessions/:session_id/skills?cwd=<path>&force_reload=true|false`

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

### `GET /api/sessions/:session_id/skills/remote`

Returns remote skills available for the session.

Response:

```json
{
  "session_id": "od-...",
  "skills": []
}
```

### `GET /api/sessions/:session_id/mcp/tools`

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
