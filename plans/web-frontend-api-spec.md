# Web Frontend — API Integration Spec

Reference for implementing the OrbitDock web client against the Rust server.
This replaces sections 2, 3, 4, and 9 of the original web frontend plan with
accurate server contract documentation.

For the exhaustive API surface, see `docs/API.md` on the server side. This
document captures the subset the web client needs, the correct integration
patterns, and the pitfalls to avoid.

---

## 1. Transport Rules

| Transport | Use for |
|-----------|---------|
| **REST** (`/api/*`) | All reads, mutations, fire-and-forget actions |
| **WebSocket** (`/ws`) | Subscriptions, real-time session interaction (send message, approve, interrupt), server-pushed events |

New clients should default to REST. Use WebSocket when the operation needs a
persistent connection (streaming rows, live status, approvals).

REST mutations often still produce WS broadcasts so other connected clients
stay in sync — the web client must handle both the REST response and any
subsequent WS events without double-counting.

Legacy WS request/response patterns return
`{ "type": "error", "code": "http_only_endpoint" }`. Do not attempt to fetch
data over WS.

---

## 2. REST Endpoints

All REST responses wrap data in named fields — never bare arrays.

### 2.1 Session Reads

```
GET /api/sessions
→ { sessions: SessionListItem[] }

GET /api/sessions/{id}
→ { session: SessionState }

GET /api/sessions/{id}/conversation?limit=N&before_sequence=S
→ {
    session: { rows, total_row_count, has_more_before, oldest_sequence, newest_sequence },
    total_row_count,
    has_more_before,
    oldest_sequence,
    newest_sequence
  }

GET /api/sessions/{id}/messages?before_sequence=S&limit=N
→ { rows, total_row_count, has_more_before, oldest_sequence, newest_sequence }

GET /api/sessions/{id}/rows/{row_id}/content
→ { row_id, input_display?, output_display?, diff_display?, language?, start_line? }

GET /api/sessions/{id}/stats
→ { session_id, total_rows, tool_count, ... }
```

`/conversation` is the initial bootstrap endpoint (conversation rows +
pagination metadata). `/messages` is for infinite-scroll pagination of older
rows using `before_sequence`.

### 2.2 Session Lifecycle

```
POST /api/sessions              — create direct session
  body: { provider, cwd, model?, ... }
  → { session_id, session }

POST /api/sessions/{id}/resume  — resume persisted session
POST /api/sessions/{id}/end     — end session
POST /api/sessions/{id}/fork    — fork session
PATCH /api/sessions/{id}/name   — rename session
  body: { name }
```

### 2.3 Session Actions

```
POST /api/sessions/{id}/messages
  body: { content, model?, effort?, skills?, images?, mentions? }
  → { accepted, row }          (returns the user's ConversationRowEntry)

POST /api/sessions/{id}/steer
  body: { content }

POST /api/sessions/{id}/interrupt
POST /api/sessions/{id}/compact
POST /api/sessions/{id}/undo
POST /api/sessions/{id}/rollback
  body: { num_turns }
```

### 2.4 Approvals

All three approval endpoints share the same response shape:
`{ session_id, request_id, outcome, active_request_id, approval_version }`

```
POST /api/sessions/{id}/approve
  body: { request_id, decision, message?, interrupt?, updated_input? }

POST /api/sessions/{id}/answer
  body: { request_id, answer?, question_id?, answers? }

POST /api/sessions/{id}/permissions/respond
  body: { request_id, permissions?, scope? }
```

### 2.5 Server & Config

```
GET  /health                    → { status: "ok" }
GET  /api/models/claude         → { models: ClaudeModelOption[] }
GET  /api/models/codex          → { models: CodexModelOption[] }
GET  /api/usage/claude          → { usage?, error_info? }
GET  /api/usage/codex           → { usage?, error_info? }
GET  /api/server/openai-key     → { configured: bool }
POST /api/server/openai-key     — store key
GET  /api/server/linear-key     → { configured: bool }
```

### 2.6 Response Envelope Patterns

```
Success (read):       { sessions: [...] } / { session: {...} } / { rows: [...] }
Success (mutation):   { accepted: true } or { ok: true }
Success (approval):   { session_id, request_id, outcome, ... }
Error:                { code: "string_code", error: "human message" }
```

---

## 3. WebSocket Contract (`/ws`)

### 3.1 Connection Lifecycle

1. Client opens `ws://host/ws`
2. Server immediately sends `server_info { is_primary, client_primary_claims[] }`
3. Client sends subscriptions

### 3.2 Client → Server Messages

All messages are JSON, discriminated on the `type` field, `snake_case`.

#### Subscriptions

```jsonc
// Register for incremental session list broadcasts.
// Does NOT send initial list — that comes from GET /api/sessions.
{ "type": "subscribe_list" }

// Register for session-level updates.
// include_snapshot: true returns http_only_endpoint error.
// Initial data comes from GET /api/sessions/{id}/conversation.
{ "type": "subscribe_session", "session_id": "...", "since_revision": null, "include_snapshot": false }

{ "type": "unsubscribe_session", "session_id": "..." }
```

#### Session Interaction (WS-only, needs persistent connection)

```jsonc
{ "type": "send_message", "session_id": "...", "content": "...",
  "model?": "...", "effort?": "...", "skills?": [], "images?": [], "mentions?": [] }

{ "type": "approve_tool", "session_id": "...", "request_id": "...",
  "decision": "approve|deny", "message?": "...", "interrupt?": false, "updated_input?": null }

{ "type": "answer_question", "session_id": "...", "request_id": "...",
  "answer": "...", "question_id?": "...", "answers?": [] }

{ "type": "respond_to_permission_request", "session_id": "...", "request_id": "...",
  "permissions?": [], "scope?": "..." }

{ "type": "interrupt_session", "session_id": "..." }
{ "type": "end_session", "session_id": "..." }
```

#### Session Management (WS)

```jsonc
{ "type": "create_session", "provider": "...", "cwd": "...", "model?": "..." }
{ "type": "resume_session", "session_id": "..." }
{ "type": "rename_session", "session_id": "...", "name?": "..." }
{ "type": "compact_context", "session_id": "..." }
{ "type": "undo_last_turn", "session_id": "..." }
{ "type": "rollback_turns", "session_id": "...", "num_turns": 2 }
{ "type": "steer_turn", "session_id": "...", "content": "..." }
{ "type": "fork_session", "session_id": "...", "nth_user_message?": null }
```

### 3.3 Server → Client Messages

#### List-level (after `subscribe_list`)

| Type | Payload | Notes |
|------|---------|-------|
| `session_created` | `{ session: SessionListItem }` | New session appeared |
| `session_list_item_updated` | `{ session: SessionListItem }` | Metadata changed |
| `session_list_item_removed` | `{ session_id }` | Session deleted |
| `session_ended` | `{ session_id, reason }` | Session terminated |
| `session_forked` | `{ source_session_id, new_session_id, forked_from_thread_id? }` | Fork created |

#### Session-level (after `subscribe_session`)

| Type | Payload | Notes |
|------|---------|-------|
| `conversation_rows_changed` | `{ session_id, upserted: RowEntrySummary[], removed_row_ids: string[], total_row_count }` | Incremental row updates |
| `session_delta` | `{ session_id, changes: StateChanges }` | Status, work_status, pending_approval, tokens, name, summary, etc. |
| `approval_requested` | `{ session_id, request: ApprovalRequest, approval_version? }` | Tool needs approval |
| `approval_decision_result` | `{ session_id, request_id, outcome, active_request_id?, approval_version }` | Approval outcome |
| `tokens_updated` | `{ session_id, usage: TokenUsage, snapshot_kind }` | Token usage |
| `context_compacted` | `{ session_id }` | Context was compacted |
| `undo_started` / `undo_completed` | `{ session_id, message?, success? }` | Undo lifecycle |
| `thread_rolled_back` | `{ session_id, num_turns }` | Rollback applied |
| `rate_limit_event` | `{ session_id, info }` | Rate limit hit |
| `prompt_suggestion` | `{ session_id, suggestion }` | Suggested prompt |
| `files_persisted` | `{ session_id, files[] }` | Files saved |

#### Error

```jsonc
{ "type": "error", "code": "...", "message": "...", "session_id?": "..." }
```

`code: "http_only_endpoint"` is returned for legacy WS patterns that tried to
fetch data.

---

## 4. Integration Flows

These are the canonical flows the web client must implement. The critical
insight: **WS subscriptions do NOT deliver initial payloads.** They only
register the client for incremental broadcasts. Initial data always comes from
REST.

### 4.1 App Boot — Session List

```
1. Open WebSocket → /ws
2. Receive server_info (immediate, from server)
3. Send { type: "subscribe_list" }          ← registers for incremental updates
4. GET /api/sessions                         ← fetches initial session list
5. Populate sessionListStore from REST response
6. WS delivers session_created / session_list_item_updated / session_ended
   incrementally from this point forward
```

The REST fetch and WS subscription are independent — fire them in parallel. The
store must handle WS events that arrive before or after the REST response
without duplicating or dropping entries.

### 4.2 Open Session View — Conversation Bootstrap

```
1. Send { type: "subscribe_session", session_id, include_snapshot: false }
2. GET /api/sessions/{id}/conversation?limit=50   ← fetches initial rows
3. Populate conversationStore from REST response
4. WS delivers conversation_rows_changed incrementally
5. For older messages: GET /api/sessions/{id}/messages?before_sequence=X
   (REST pagination, triggered by scroll)
```

Same parallel pattern — subscribe and fetch simultaneously. The store must
merge WS upserts with the REST snapshot. Use `row_id` as the dedup key and
sequence numbers for ordering.

### 4.3 Send Message

Two options. Both are valid; choose based on architecture needs.

**Option A — REST (simpler, returns user row immediately):**

```
1. POST /api/sessions/{id}/messages { content }
2. Response includes the user's ConversationRowEntry → add to store
3. WS delivers subsequent assistant/tool rows via conversation_rows_changed
```

**Option B — WS (real-time, preferred for streaming feel):**

```
1. WS send_message { session_id, content }
2. WS delivers ALL rows (user + assistant + tools) via conversation_rows_changed
```

Option B is preferred because it keeps all row delivery on a single channel,
avoiding the need to reconcile REST-returned user rows with WS-delivered
assistant rows.

### 4.4 Approval Flow

```
1. WS receives approval_requested { session_id, request, approval_version }
2. Approval state machine: idle → pending
   (only if approval_version > high water mark — prevents stale replays)
3. UI renders approval banner with request details
4. User decides → one of:
   - POST /api/sessions/{id}/approve (REST)
   - WS approve_tool { session_id, request_id, decision }
5. State machine: pending → submitting
6. WS receives approval_decision_result { approval_version }
7. State machine: submitting → idle
```

The `approval_version` field is monotonically increasing. Always compare
against the stored high water mark to avoid processing stale or duplicate
approval requests.

### 4.5 Leave Session View

```
1. Send { type: "unsubscribe_session", session_id }
2. Clear conversationStore for that session
3. Session list continues receiving updates (subscribe_list is still active)
```

---

## 5. REST Module Reference

The `api/rest/sessions.js` module should expose these functions, matching the
server's endpoint paths exactly:

```js
const sessions = {
  // Reads
  list:           ()              => http.get('/api/sessions'),
  get:            (id)            => http.get(`/api/sessions/${id}`),
  getConversation:(id, params)    => http.get(`/api/sessions/${id}/conversation`, params),
  getMessages:    (id, params)    => http.get(`/api/sessions/${id}/messages`, params),
  getRowContent:  (sid, rid)      => http.get(`/api/sessions/${sid}/rows/${rid}/content`),
  getStats:       (id)            => http.get(`/api/sessions/${id}/stats`),

  // Lifecycle
  create:         (body)          => http.post('/api/sessions', body),
  resume:         (id)            => http.post(`/api/sessions/${id}/resume`),
  end:            (id)            => http.post(`/api/sessions/${id}/end`),
  fork:           (id, body)      => http.post(`/api/sessions/${id}/fork`, body),
  rename:         (id, body)      => http.patch(`/api/sessions/${id}/name`, body),

  // Actions
  sendMessage:    (id, body)      => http.post(`/api/sessions/${id}/messages`, body),
  steer:          (id, body)      => http.post(`/api/sessions/${id}/steer`, body),
  interrupt:      (id)            => http.post(`/api/sessions/${id}/interrupt`),
  compact:        (id)            => http.post(`/api/sessions/${id}/compact`),
  undo:           (id)            => http.post(`/api/sessions/${id}/undo`),
  rollback:       (id, body)      => http.post(`/api/sessions/${id}/rollback`, body),

  // Approvals
  approve:        (id, body)      => http.post(`/api/sessions/${id}/approve`, body),
  answer:         (id, body)      => http.post(`/api/sessions/${id}/answer`, body),
  respondPerm:    (id, body)      => http.post(`/api/sessions/${id}/permissions/respond`, body),

  // Misc
  markRead:       (id)            => http.post(`/api/sessions/${id}/mark-read`),
};
```

Note: rename uses `PATCH /api/sessions/{id}/name` (not just `/{id}`).

---

## 6. Store Reconciliation Rules

Because REST and WS operate in parallel, the stores must handle race
conditions gracefully.

### Session List Store

- **Initial load:** Replace entire store contents with `GET /api/sessions`
  response.
- **WS `session_created`:** Insert if `session_id` not already present.
- **WS `session_list_item_updated`:** Upsert — replace the matching entry.
- **WS `session_list_item_removed`:** Remove by `session_id`.
- **WS `session_ended`:** Update session status; do not remove from list.

### Conversation Store

- **Initial load:** Replace store contents with
  `GET /api/sessions/{id}/conversation` response.
- **WS `conversation_rows_changed`:** Apply upserts by `row_id` (insert or
  replace). Remove entries in `removed_row_ids`. Update `total_row_count`.
- **Pagination:** Prepend rows from `GET /api/sessions/{id}/messages` for
  older history. Use `before_sequence` to avoid overlap.
- **Ordering:** Sort rows by sequence number. Never rely on insertion order.

### Approval State

- Track `approval_version` as a high water mark.
- Only process `approval_requested` if its version exceeds the current mark.
- On `approval_decision_result`, update the mark and transition to idle.

---

## 7. WS Message Dispatch

The WebSocket message handler should dispatch on the `type` field using a
flat switch/map. Suggested grouping:

```js
const handlers = {
  // Connection
  server_info:                 handleServerInfo,

  // List-level
  session_created:             handleSessionCreated,
  session_list_item_updated:   handleSessionListItemUpdated,
  session_list_item_removed:   handleSessionListItemRemoved,
  session_ended:               handleSessionEnded,
  session_forked:              handleSessionForked,

  // Session-level
  conversation_rows_changed:   handleConversationRowsChanged,
  session_delta:               handleSessionDelta,
  approval_requested:          handleApprovalRequested,
  approval_decision_result:    handleApprovalDecisionResult,
  tokens_updated:              handleTokensUpdated,
  context_compacted:           handleContextCompacted,
  undo_started:                handleUndoStarted,
  undo_completed:              handleUndoCompleted,
  thread_rolled_back:          handleThreadRolledBack,
  rate_limit_event:            handleRateLimitEvent,
  prompt_suggestion:           handlePromptSuggestion,
  files_persisted:             handleFilesPersisted,

  // Error
  error:                       handleError,
};
```

---

## 8. Common Mistakes to Avoid

1. **Expecting WS to deliver initial data.** `subscribe_list` and
   `subscribe_session` only register for incremental broadcasts. Always fetch
   initial state from REST.

2. **Using `include_snapshot: true` on `subscribe_session`.** The server
   returns `http_only_endpoint`. Always set it to `false`.

3. **Treating REST responses as bare arrays.** Session list comes wrapped in
   `{ sessions: [...] }`, not as a bare array.

4. **Sending `PATCH` to `/api/sessions/{id}` for rename.** The correct
   endpoint is `PATCH /api/sessions/{id}/name`.

5. **Double-counting rows.** If using REST `sendMessage` (Option A), the
   response includes the user row. WS may also deliver it via
   `conversation_rows_changed`. Dedup by `row_id`.

6. **Ignoring `approval_version`.** Stale or replayed approval requests will
   cause the UI to show phantom approval banners. Always compare against the
   high water mark.

7. **Attempting data fetches over WS.** Any legacy request/response pattern
   returns `{ type: "error", code: "http_only_endpoint" }`. Use REST for all
   reads.
