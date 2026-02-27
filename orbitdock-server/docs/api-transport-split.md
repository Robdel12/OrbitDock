# API Transport Split: REST for State, WebSocket for Realtime

## Problem

The current server protocol multiplexes three different concerns over WebSocket:

1. Bootstrap reads (sessions list, full session snapshots)
2. Request/response utilities (directory browse, usage reads, key checks, approvals list, etc.)
3. Realtime streams (session deltas, appended messages, approval/tokens events)

That coupling creates two recurring issues:

- Large one-shot payloads are constrained by WebSocket frame limits (forcing compaction/truncation behavior).
- Simple request/response paths require custom correlation logic (`request_id`) and continuation bookkeeping.

## Transport Boundary

Use **REST as the source of truth for load/read operations**, and **WebSocket only for push/realtime deltas**.

### WebSocket should keep

- `subscribe_list`
- `subscribe_session`
- `unsubscribe_session`
- Realtime server events (`session_delta`, `message_appended`, `message_updated`, `approval_requested`, `tokens_updated`, lifecycle notifications)

### Move to REST

- Initial session list
- Initial session snapshot/history
- One-shot utilities currently modeled as WS request/response:
  - approvals list/delete
  - models/account/usage reads
  - directory browse/recent projects
  - review comment list/read paths
  - subagent tool reads

### Write paths (next phase)

Move command-style actions to REST (`POST`/`PATCH`), keep WS as event stream:

- send message / steer turn / approve / answer / interrupt / end / rename / config updates

This lets writes return immediate HTTP ack semantics while the UI still updates from WS events.

## Phase 1 (implemented)

- Added `GET /api/sessions`
- Added `GET /api/sessions/{session_id}`
- Added `include_snapshot` flag on WS `subscribe_session` (defaults `true` for backward compatibility)
- App flow now:
  1. HTTP fetch session snapshot
  2. WS subscribe with `since_revision` and `include_snapshot=false`

Result: large bootstrap payloads no longer need WS transport compaction/truncation.

## Phase 2 (implemented)

- Added utility/read REST endpoints:
  - `GET /api/models/codex`
  - `GET /api/models/claude`
  - `GET /api/codex/account`
  - `GET /api/sessions/{session_id}/review-comments`
  - `GET /api/sessions/{session_id}/subagents/{subagent_id}/tools`
  - `GET /api/sessions/{session_id}/skills`
  - `GET /api/sessions/{session_id}/skills/remote`
  - `GET /api/sessions/{session_id}/mcp/tools`
- Swift client now uses HTTP for these read paths.
- Legacy WS request/response handlers for these read/list operations now return
  `error.code = "http_only_endpoint"` so read traffic cannot regress back to WS.
- Connector-bound read endpoints can return `409` (`code = "session_not_found"`) while a
  direct connector is not yet available; clients should treat this as transient availability,
  not as an MCP auth/startup failure.

## Phase 3 (implemented)

- Added mutation REST endpoints for 14 operations that were previously WS-only:
  - Config: `POST /api/server/openai-key`, `PUT /api/server/role`
  - Worktrees: `GET /api/worktrees`, `POST /api/worktrees`, `POST /api/worktrees/discover`, `DELETE /api/worktrees/{id}`
  - Review comments: `POST /api/sessions/{id}/review-comments`, `PATCH /api/review-comments/{id}`, `DELETE /api/review-comments/{id}`
  - Codex auth: `POST /api/codex/login/start`, `POST /api/codex/login/cancel`, `POST /api/codex/logout`
  - Async actions: `POST /api/sessions/{id}/skills/download` (202), `POST /api/sessions/{id}/mcp/refresh` (202)
- Swift client now calls REST for all mutations. `ServerConnection.swift` uses `requestAPIJSON(path:method:body:)` with `convertToSnakeCase` encoding.
- WS handlers for these variants now return `error.code = "http_only_endpoint"` (via `ws_handlers/rest_only.rs`).
- Server still broadcasts events (e.g. `ReviewCommentCreated`, `ServerInfo`) via WS after REST mutations — WS response handlers in the client remain in place.
- `ClientToServerMessage` enum cases are dead code but kept for protocol backward compatibility. Prune in follow-up.

## Next Migration Steps

1. Add paged message/history endpoints (`limit` + cursor/revision) for very large sessions.
2. Keep WS event-only protocol small and stable; remove obsolete WS message variants from protocol once all clients are on current builds.
3. Consider moving session commands (create, send, approve, interrupt) to REST for HTTP ack semantics.
