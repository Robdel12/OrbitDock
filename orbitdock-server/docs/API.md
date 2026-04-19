# OrbitDock Server API

Last updated: 2026-04-17

This file is the route-level contract for OrbitDock's Rust server.

It is intentionally boring:

- HTTP owns bootstrap reads, pagination, settings/config reads, uploads, and mutation responses.
- WebSocket owns realtime deltas, replay, heartbeats, and explicit refetch hints.
- Clients should apply authoritative HTTP mutation responses immediately, then let WebSocket reconcile.

This doc was rewritten against the real router in:

- `orbitdock-server/crates/server/src/transport/http/router.rs`
- `orbitdock-server/crates/server/src/transport/http/*`
- `OrbitDockNative/OrbitDock/Services/Server/API/*`

## Transport rules

- Use REST for all initial reads and all heavy payloads.
- Use `GET /ws` only after bootstrapping the surface over HTTP.
- Treat WebSocket invalidations as refetch hints, not as a second bootstrap path.
- Successful mutations often include an authoritative snapshot. Apply that snapshot immediately.

## Auth

Everything except `GET /health` requires the normal OrbitDock bearer token:

```http
Authorization: Bearer <token>
```

Workspace sync uses the same header name but a different token class. `POST /api/sync` expects a workspace sync token, not the normal app token.

## Common response shapes

### `ApiErrorResponse`

```json
{
  "code": "string_code",
  "error": "human readable message"
}
```

### `AcceptedResponse`

Used by many fire-and-forget session mutations.

```json
{
  "accepted": true,
  "session_detail_snapshot": {
    "revision": 123,
    "session": { "...": "..." }
  }
}
```

`session_detail_snapshot` is optional. When present, it is authoritative and should be applied immediately.

### `SendMessageResponse`

Used by `POST /api/sessions/{session_id}/conversation/messages`.

```json
{
  "accepted": true,
  "row": { "...ConversationRowEntry..." },
  "session_detail_snapshot": { "...optional SessionDetailSnapshot..." }
}
```

### `SteerTurnResponse`

Used by `POST /api/sessions/{session_id}/conversation/steer`.

```json
{
  "accepted": true,
  "row": { "...ConversationRowEntry..." },
  "session_detail_snapshot": { "...optional SessionDetailSnapshot..." }
}
```

### `SessionDetailSnapshot`

Used by `GET /api/sessions/{session_id}/detail` and several session mutations.

Top-level fields:

- `revision`
- `session`

`session` is the authoritative session shell for detail/control-deck style UI. It does not include the full conversation timeline.

Important control-deck fields:

- `work_status` — display status only; do not use it as a proxy for individual actions.
- `connector_attached` — true when the live connector action channel is attached.
- `accepts_user_input` — true when a direct/open session can receive a new user turn through the attached connector.
- `steerable` — true when the current turn can receive steering feedback through the attached connector.
- `can_interrupt` — true only when the server knows an active turn can be interrupted through the attached connector.
- `current_turn_id` — current active turn identity, when one exists.

### `MissionDetailResponse`

Used by `GET /api/missions/{mission_id}` and most mission mutations.

Top-level fields:

- `summary`
- `issues`
- `cleanup_prompt`
- `settings`
- `mission_file_exists`
- `mission_file_path`
- `workflow_migration_available`

## HTTP endpoints

## Core

### `GET /health`

Returns:

```json
{"status":"ok"}
```

### `GET /metrics`

Returns Prometheus-style metrics text.

### `POST /api/hook`

Internal Claude hook-forward ingestion endpoint.

- Not intended for normal UI clients.
- Accepts forwarded hook JSON with an injected `type`.
- Returns `200 OK` with an acknowledgement payload.

## Sessions

### Global session surfaces

There is no `GET /api/sessions` list route.

Clients should use the explicit surface routes below:

### `GET /api/sessions/summary`

Compact global session shell for quick switcher, menu bar, and attention UI.

Returns:

- `revision`
- `counts`
- `active_sessions`
- `recent_sessions`

### `GET /api/sessions/active`

Authoritative dashboard surface.

Returns:

- `revision`
- `conversations`
- `counts`
- `project_groups`

### `GET /api/sessions/archive?limit=<n>&offset=<n>`

Authoritative library/archive surface.

Returns:

- `revision`
- `sessions`
- `next_offset`
- `total_count`

### Session detail and conversation

### `GET /api/sessions/{session_id}/detail`

Returns the authoritative `SessionDetailSnapshot`.

### `PATCH /api/sessions/{session_id}/detail/config`

Updates stored session config and returns the authoritative `SessionDetailSnapshot`.

This is the only session config mutation route. There is no separate `PATCH /api/sessions/{session_id}/detail` mutation alias.

### `POST /api/sessions/{session_id}/detail/read`

Marks the session as read.

Returns:

```json
{
  "session_id": "od-...",
  "unread_count": 0
}
```

### `GET /api/sessions/{session_id}/conversation?limit=<n>&before_sequence=<seq>`

Conversation bootstrap surface.

Returns:

- `session`
- `total_row_count`
- `has_more_before`
- `oldest_sequence`
- `newest_sequence`

`session` includes the first page of typed `ConversationRowEntry` values in `rows`.

### `GET /api/sessions/{session_id}/conversation/messages?before_sequence=<seq>&limit=<n>`

Returns an older paged slice of conversation rows.

### `GET /api/sessions/{session_id}/conversation/search?...`

Searches conversation rows within a session.

Supported query params:

- `q`
- `family`
- `status`
- `kind`

### `GET /api/sessions/{session_id}/conversation/stats`

Returns aggregate conversation/session metrics used by detail/review surfaces.

### `GET /api/sessions/{session_id}/conversation/rows/{row_id}/content`

Returns expanded content for a single row, such as tool input/output or diff content.

### `GET /api/sessions/{session_id}/review`

Returns the review surface bootstrap for a session.

Top-level fields include:

- `session_id`
- `revision`
- `current_diff`
- `cumulative_diff`
- `turn_diffs`
- `comments`

### Session lifecycle

### `POST /api/sessions`

Creates a direct session.

Returns:

- `session_id`
- `session` as a `SessionSummary`

### `POST /api/sessions/{session_id}/lifecycle/resume`

Resumes a persisted session.

Returns:

- `session_id`
- `session` as a `SessionSummary`
- optional `session_detail_snapshot`

### `POST /api/sessions/{session_id}/lifecycle/takeover`

Takes over a passive session.

Returns:

- `session_id`
- `accepted`
- optional `session_detail_snapshot`

### `POST /api/sessions/{session_id}/lifecycle/end`

Ends a session.

Returns `AcceptedResponse`.

### `POST /api/sessions/{session_id}/lifecycle/fork`

Forks a session.

Returns:

- `source_session_id`
- `new_session_id`
- `session` as a `SessionSummary`

### `POST /api/sessions/{session_id}/lifecycle/fork/worktree`

Creates a worktree, then forks into it.

Returns the fork payload plus:

- `worktree`

### `POST /api/sessions/{session_id}/lifecycle/fork/existing-worktree`

Forks into an existing tracked worktree.

Returns the same fork payload as `POST /lifecycle/fork`.

### Session messaging and actions

### `POST /api/sessions/{session_id}/conversation/messages`

Queues a user turn.

Returns `202 Accepted` with `SendMessageResponse`.

### `POST /api/sessions/{session_id}/conversation/steer`

Queues a steer message for the active turn.

Returns `202 Accepted` with `SteerTurnResponse`.

### `POST /api/sessions/{session_id}/conversation/interrupt`

Returns `AcceptedResponse`.

### `POST /api/sessions/{session_id}/conversation/compact`

Returns `AcceptedResponse`.

### `POST /api/sessions/{session_id}/conversation/undo`

Returns `AcceptedResponse`.

### `POST /api/sessions/{session_id}/conversation/rollback`

Returns `AcceptedResponse`.

Request body:

```json
{"num_turns": 2}
```

### `POST /api/sessions/{session_id}/conversation/stop`

Stops a running task.

Request body:

```json
{"task_id":"task-..."}
```

Returns `AcceptedResponse`.

### `POST /api/sessions/{session_id}/conversation/rewind`

Rewinds files to a user message boundary.

Request body:

```json
{"user_message_id":"msg-..."}
```

Returns `AcceptedResponse`.

### Session attachments and shell

### `POST /api/sessions/{session_id}/conversation/attachments/images`

Uploads an image attachment.

- Request body is raw image bytes.
- `Content-Type` is required.
- Query params:
  - `display_name`
  - `pixel_width`
  - `pixel_height`

Returns:

```json
{
  "image": {
    "input_type": "attachment",
    "value": "attachment-...",
    "mime_type": "image/png"
  }
}
```

### `GET /api/sessions/{session_id}/conversation/attachments/images/{attachment_id}`

Returns raw attachment bytes with the stored image content type.

### `POST /api/sessions/{session_id}/conversation/shell/exec`

Starts a shell command in the session context.

Returns:

```json
{
  "request_id": "shell-...",
  "accepted": true
}
```

Shell output streams over WebSocket.

### `POST /api/sessions/{session_id}/conversation/shell/cancel`

Cancels an active shell request.

Returns `AcceptedResponse` with `session_detail_snapshot` omitted.

### Session naming

### `PATCH /api/sessions/{session_id}/detail/name`

Sets or clears a custom session name.

Returns `AcceptedResponse`.

### `PATCH /api/sessions/{session_id}/detail/summary`

Sets or clears a custom session summary.

Returns `AcceptedResponse`.

## Session approvals, permissions, and review comments

### `GET /api/approvals?session_id=<id>&limit=<n>`

Returns:

- `session_id`
- `approvals`

### `DELETE /api/approvals/{approval_id}`

Deletes one approval row.

Returns:

```json
{
  "approval_id": 42,
  "deleted": true
}
```

### `POST /api/sessions/{session_id}/approvals/requests/{request_id}/decision`

Applies a tool approval decision.

### `POST /api/sessions/{session_id}/questions/requests/{request_id}/answer`

Answers a question request.

### `POST /api/sessions/{session_id}/permissions/requests/{request_id}/response`

Responds to a permission grant request.

All three routes return the same shape:

- `session_id`
- `request_id`
- `outcome`
- `active_request_id`
- `approval_version`
- optional `session_detail_snapshot`

### `GET /api/sessions/{session_id}/review/comments?turn_id=<turn-id>`

Returns:

- `session_id`
- `review_revision`
- `comments`

### `POST /api/sessions/{session_id}/review/comments`

Creates a review comment.

Returns:

- `session_id`
- `review_revision`
- `comment_id`
- `comment`
- `deleted`
- `ok`

### `PATCH /api/review/comments/{comment_id}`

Updates a review comment.

Returns the same review comment mutation payload as create.

### `DELETE /api/review/comments/{comment_id}`

Deletes a review comment.

Returns the same review comment mutation payload with:

- `comment: null`
- `deleted: true`

## Session capabilities

These routes are still grouped under `capabilities`, but the intended client model is simple:

- use HTTP to read or mutate session support/config state
- use WebSocket only for follow-up deltas or refetch hints

### `GET /api/sessions/{session_id}/subagents/{subagent_id}/tools`

Returns:

- `session_id`
- `subagent_id`
- `tools`

If the subagent transcript cannot be read, `tools` is empty.

### `GET /api/sessions/{session_id}/subagents/{subagent_id}/messages`

Returns:

- `session_id`
- `subagent_id`
- `rows`

If the subagent transcript cannot be read, `rows` is empty.

### `GET /api/sessions/{session_id}/instructions`

Returns:

- `session_id`
- `provider`
- `instructions`

For Claude, `instructions` can include merged `claude_md`.

### `GET /api/sessions/{session_id}/skills`

Query params:

- repeatable `cwd`
- `force_reload`

Returns:

- `session_id`
- `skills`
- `claude_skill_names`
- `errors`

### `GET /api/sessions/{session_id}/plugins`

Query params:

- repeatable `cwd`
- `force_remote_sync`

Returns plugin marketplace state for the session.

### `POST /api/sessions/{session_id}/plugins/install`

Installs a plugin.

Returns the install result from Codex App Server, including auth requirements when applicable.

### `POST /api/sessions/{session_id}/plugins/uninstall`

Uninstalls a plugin.

Returns the uninstall result from Codex App Server.

### `GET /api/sessions/{session_id}/mcp`

Returns:

- `session_id`
- `tools`
- `resources`
- `resource_templates`
- `auth_statuses`

### `POST /api/sessions/{session_id}/mcp/refresh`

Refreshes MCP server state.

Returns `AcceptedResponse` with no detail snapshot.

### `POST /api/sessions/{session_id}/mcp/toggle`

Toggles a Claude MCP server.

Returns `AcceptedResponse` with no detail snapshot.

### `POST /api/sessions/{session_id}/mcp/authenticate`

Starts MCP auth flow for a server.

Returns `AcceptedResponse` with no detail snapshot.

### `POST /api/sessions/{session_id}/mcp/clear-auth`

Clears MCP auth state for a server.

Returns `AcceptedResponse` with no detail snapshot.

### `POST /api/sessions/{session_id}/mcp/servers`

Sets the Claude MCP server config payload.

Returns `AcceptedResponse` with no detail snapshot.

### `POST /api/sessions/{session_id}/flags`

Applies Claude flag/settings payload.

Returns `AcceptedResponse` with no detail snapshot.

### `GET /api/sessions/{session_id}/permissions/rules`

Returns the session permission rules view.

For Claude, this is derived from CLI/disk settings.
For Codex, this reflects approval and sandbox policy state.

### `POST /api/sessions/{session_id}/permissions/rules`

Adds a permission rule.

### `DELETE /api/sessions/{session_id}/permissions/rules`

Removes a permission rule.

Both routes return:

```json
{
  "ok": true,
  "session_detail_snapshot": { "...optional SessionDetailSnapshot..." }
}
```

## Server and app-shell configuration

### `GET /api/server/meta`

Returns the server meta payload used by the app shell.

### `GET /api/server/openai-key`

Returns:

```json
{"configured": true}
```

### `POST /api/server/openai-key`

Stores the OpenAI key and returns the same `configured` shape.

### `GET /api/server/workspace-provider`

Returns the active workspace provider:

```json
{"workspace_provider":"local"}
```

### `PUT /api/server/workspace-provider`

Updates the active workspace provider and returns the same shape.

### `GET /api/server/workspace-provider/config/{key}`

Returns:

- `key`
- `value`
- `configured`
- `secret`
- `source`

### `PUT /api/server/workspace-provider/config/{key}`

Writes one workspace-provider config value and returns the same config-value shape.

### `POST /api/server/workspace-provider/test`

Runs a provider preflight test.

Returns:

- `ok`
- `provider`
- `message`

### `PUT /api/server/role`

Sets server primary/secondary role.

Returns:

```json
{"is_primary":true}
```

### `POST /api/client/primary-claim`

Stores a client primary-claim preference.

Returns `AcceptedResponse` with no detail snapshot.

### Update endpoints

### `GET /api/server/update-status`

Returns current update status payload.

### `POST /api/server/check-update`

Triggers an update check.

### `POST /api/server/start-upgrade`

Starts the upgrade flow.

### `GET /api/server/update-channel`

Returns the current update channel.

### `PUT /api/server/update-channel`

Sets the update channel and returns the same shape.

### Usage and model endpoints

### `GET /api/usage/summary`

Returns the combined usage summary snapshot.

### `GET /api/usage/codex`

Returns Codex-specific usage snapshot.

### `GET /api/usage/claude`

Returns Claude-specific usage snapshot.

### `GET /api/models/codex`

Returns available Codex models for the current server/runtime context.

### `GET /api/models/claude`

Returns available Claude models for the current server/runtime context.

## Codex account and config

### `GET /api/codex/account`

Returns Codex account/auth status.

### `POST /api/codex/config/inspect`

Returns the inspected effective Codex config for a working directory.

### `GET /api/codex/config/catalog?cwd=<path>`

Returns Codex config profiles, providers, effective values, and warnings for a cwd.

### `GET /api/codex/config/documents?cwd=<path>`

Returns raw user/project Codex config documents and warnings.

### `POST /api/codex/config/value`

Writes one Codex config value.

### `POST /api/codex/config/batch-write`

Writes multiple Codex config values atomically.

Both write routes return a write result that includes:

- `status`
- `version`
- `file_path`

### `POST /api/codex/login/start`

Starts Codex login.

### `POST /api/codex/login/cancel`

Cancels Codex login.

### `POST /api/codex/logout`

Logs out of Codex.

### `GET /api/server/codex-preferences`

Returns server-level Codex preferences.

### `PUT /api/server/codex-preferences`

Updates server-level Codex preferences and returns the same shape.

## Filesystem, sync, and worktrees

### `POST /api/git/init`

Runs `git init` in the provided path.

Returns:

```json
{"ok":true}
```

### `GET /api/fs/browse?path=<path>`

Returns:

- `path`
- `entries`

### `GET /api/fs/recent-projects`

Returns:

- `projects`

### `POST /api/sync`

Workspace sync ingestion endpoint.

- Requires a workspace sync bearer token.
- Applies a `SyncBatchRequest`.
- Returns:

```json
{
  "acked_through": 42
}
```

- Can return:
  - `401 missing_bearer_token`
  - `401 invalid_workspace_token`
  - `401 workspace_not_found`
  - `409 sync_sequence_conflict`

### `GET /api/worktrees?repo_root=<path>`

Returns:

- `repo_root`
- `worktree_revision`
- `worktrees`

### `POST /api/worktrees`

Creates a tracked worktree and returns:

- `repo_root`
- `worktree_revision`
- `worktree`

### `POST /api/worktrees/discover`

Discovers worktrees for a repo root and returns the same surface shape as `GET /api/worktrees`.

### `DELETE /api/worktrees/{worktree_id}`

Removes or archives a worktree.

Query params:

- `force`
- `delete_branch`
- `delete_remote_branch`
- `archive_only`

Returns:

- `repo_root`
- `worktree_revision`
- `worktree_id`
- `deleted`
- `ok`

## Mission Control

### Missions list and detail

### `GET /api/missions`

Returns:

- `missions`

### `POST /api/missions`

Creates a mission.

Returns one `MissionSummary`.

### `GET /api/missions/{mission_id}`

Returns `MissionDetailResponse`.

This is the authoritative mission detail bootstrap.

### `PUT /api/missions/{mission_id}`

Updates mission metadata and returns `MissionDetailResponse`.

### `DELETE /api/missions/{mission_id}`

Deletes the mission and returns:

- `missions`

### `GET /api/missions/{mission_id}/issues`

Returns the mission issue list as an array of `MissionIssueItem`.

### Issue mutations

### `POST /api/missions/{mission_id}/issues/{issue_id}/retry`

Retries/requeues an issue and returns `MissionDetailResponse`.

### `POST /api/missions/{mission_id}/issues/{issue_id}/transition`

Applies an admin transition and returns `MissionDetailResponse`.

### `POST /api/missions/{mission_id}/issues/{issue_id}/complete`

Marks an issue completed and returns `MissionDetailResponse`.

### `POST /api/missions/{mission_id}/issues/{issue_id}/pr`

Stores a PR URL and returns `MissionDetailResponse`.

### `POST /api/missions/{mission_id}/issues/{issue_id}/blocked`

Marks an issue blocked and returns `MissionDetailResponse`.

### Mission setup and settings

### `POST /api/missions/{mission_id}/scaffold`

Creates a default `MISSION.md` and returns `MissionDetailResponse`.

### `POST /api/missions/{mission_id}/migrate-workflow`

Migrates `WORKFLOW.md` to `MISSION.md` and returns `MissionDetailResponse`.

### `GET /api/missions/{mission_id}/default-template`

Returns:

```json
{"template":"..."}
```

### `PUT /api/missions/{mission_id}/settings`

Writes merged mission settings and returns `MissionDetailResponse`.

### Mission orchestrator endpoints

### `POST /api/missions/{mission_id}/start-orchestrator`

Starts the mission orchestrator.

Returns:

```json
{"ok":true}
```

### `POST /api/missions/{mission_id}/dispatch`

Manually dispatches a tracker issue and returns `MissionDetailResponse`.

### `POST /api/missions/{mission_id}/trigger`

Triggers an immediate poll tick.

Returns:

```json
{"ok":true}
```

### Mission worktrees

### `GET /api/missions/{mission_id}/worktrees`

Returns:

```json
{"worktrees":[...]}
```

### Mission-scoped tracker keys

### `GET /api/missions/{mission_id}/tracker-key`

Returns:

```json
{
  "configured": true,
  "source": "mission"
}
```

### `PUT /api/missions/{mission_id}/tracker-key`

Stores a mission-scoped tracker key and returns the same shape.

### `DELETE /api/missions/{mission_id}/tracker-key`

Deletes the mission-scoped tracker key and returns the same shape.

### `POST /api/missions/{mission_id}/adopt-global-key`

Copies the resolved global tracker key into mission scope and returns the same shape.

### Global tracker/server mission config

### `GET /api/server/linear-key`
### `POST /api/server/linear-key`
### `DELETE /api/server/linear-key`

All three use:

```json
{"configured":true}
```

### `GET /api/server/github-key`
### `POST /api/server/github-key`
### `DELETE /api/server/github-key`

All three use:

```json
{"configured":true}
```

### `GET /api/server/tracker-keys`

Returns:

- `linear`
- `github`

Each provider entry contains:

- `configured`
- `source`

### `GET /api/server/mission-defaults`

Returns:

- `provider_strategy`
- `primary_provider`
- `secondary_provider`

### `PUT /api/server/mission-defaults`

Updates mission defaults and returns the same shape.

## WebSocket

### `GET /ws`

The client should:

1. fetch the relevant HTTP surface first
2. remember that surface revision
3. subscribe over WebSocket with `since_revision`
4. refetch the exact HTTP surface only when the socket reports a gap or invalidation

### Handshake

The server sends `hello` immediately after connect.

The handshake advertises:

- `server_version`
- compatibility info
- capabilities

### Subscription messages

Common client messages:

- `subscribe_sessions_summary`
- `subscribe_active_sessions`
- `subscribe_archived_sessions`
- `subscribe_missions`
- `subscribe_session_surface`
- `unsubscribe_session_surface`

All subscription messages support `since_revision`.

### Important server-pushed message families

- `sessions_summary_invalidated`
- `active_sessions_invalidated`
- `archived_sessions_invalidated`
- `missions_invalidated`
- `mission_invalidated`
- `conversation_rows_changed`
- `session_delta`
- `approval_requested`
- `approval_decision_result`
- `shell_started`
- `shell_output`
- `review_comment_created`
- `review_comment_updated`
- `review_comment_deleted`
- `worktree_created`
- `worktree_removed`
- `worktree_status_changed`

### Realtime contract

- Do not treat WebSocket as a bootstrap transport.
- Do not assume invalidations contain enough state to rebuild a surface.
- Use HTTP for authoritative snapshots.
- Use WebSocket for deltas, replay, and explicit refetch signals only.
