# OrbitDock Web Frontend Spec

Implementation guide for building a web client for OrbitDock. Framework-agnostic — describes what the client must do, not how.

The server (`orbitdock`) owns all state. The web client is a thin, reactive view over REST + WebSocket. For the exhaustive server API surface, see `orbitdock-server/docs/API.md`.

---

## Transport Rules

| Transport | Use for |
|-----------|---------|
| **REST** (`/api/*`) | All reads, mutations, fire-and-forget actions |
| **WebSocket** (`/ws`) | Subscriptions, real-time session interaction, server-pushed events |

Default to REST. Only use WebSocket when the operation needs a persistent connection (streaming rows, live status, approvals).

REST mutations often produce WS broadcasts so other connected clients stay in sync — the client must handle both the REST response and subsequent WS events without double-counting.

**Critical**: WS subscriptions do NOT deliver initial payloads. They only register for incremental broadcasts. Initial data always comes from REST.

---

## Integration Flows

### App Boot — Session List

```
1. Open WebSocket → /ws
2. Receive server_info { is_primary, client_primary_claims[] }
3. Send { type: "subscribe_list" }          ← registers for incremental updates
4. GET /api/sessions                         ← fetches initial session list
5. Populate session store from REST response (wrapped: { sessions: [...] })
6. WS delivers session_created / session_list_item_updated / session_ended
   incrementally from this point forward
```

REST fetch and WS subscription are independent — fire them in parallel. The store must handle WS events arriving before or after the REST response without duplication.

### Open Session — Conversation Bootstrap

```
1. Send { type: "subscribe_session", session_id, include_snapshot: false }
2. GET /api/sessions/{id}/conversation?limit=50    ← initial rows
3. Populate conversation store from REST response
4. WS delivers conversation_rows_changed incrementally
5. For older messages: GET /api/sessions/{id}/messages?before_sequence=X
```

`include_snapshot: true` returns an `http_only_endpoint` error. Always false.

`/conversation` is the initial bootstrap. `/messages?before_sequence=X` is for infinite-scroll pagination.

### Send Message

**Option A — REST (returns user row immediately):**
```
1. POST /api/sessions/{id}/messages { content }
2. Response includes the user's ConversationRowEntry
3. WS delivers assistant/tool rows via conversation_rows_changed
```

**Option B — WS (preferred, single delivery channel):**
```
1. WS send_message { session_id, content }
2. WS delivers ALL rows (user + assistant + tools) via conversation_rows_changed
```

Option B avoids reconciling REST-returned user rows with WS-delivered assistant rows.

### Approval Flow

```
1. WS receives approval_requested { session_id, request, approval_version }
2. Only process if approval_version > stored high water mark
3. Render approval UI based on request.type (exec/patch/question/permissions)
4. User decides → POST /api/sessions/{id}/approve (or /answer, /permissions/respond)
5. WS receives approval_decision_result { approval_version }
6. Update high water mark, clear pending state
```

`approval_version` is monotonically increasing. Stale/replayed requests must be rejected.

### Leave Session

```
1. Send { type: "unsubscribe_session", session_id }
2. Clear conversation store
3. Session list continues receiving updates (subscribe_list stays active)
```

---

## REST Endpoints

All responses wrap data in named fields — never bare arrays.

### Session Reads

```
GET /api/sessions                                    → { sessions: SessionListItem[] }
GET /api/sessions/{id}                               → { session: SessionState }
GET /api/sessions/{id}/conversation?limit=N&before_sequence=S
    → { session: { rows, total_row_count, has_more_before, oldest_sequence, newest_sequence } }
GET /api/sessions/{id}/messages?before_sequence=S&limit=N
    → { rows, total_row_count, has_more_before, oldest_sequence, newest_sequence }
GET /api/sessions/{id}/rows/{row_id}/content         → { row_id, input_display?, output_display?, diff_display? }
GET /api/sessions/{id}/stats                         → { session_id, total_rows, tool_count, ... }
GET /api/sessions/{id}/search?q=&family=&status=     → { rows, total_row_count, ... }
```

### Session Lifecycle

```
POST  /api/sessions                    create (body: { provider, cwd, model?, ... })
POST  /api/sessions/{id}/resume        resume persisted session
POST  /api/sessions/{id}/end           end session
POST  /api/sessions/{id}/fork          fork (body: { nth_user_message?, model?, ... })
POST  /api/sessions/{id}/takeover      take over passive session
PATCH /api/sessions/{id}/name          rename (body: { name })       ← NOTE: /name not /{id}
PATCH /api/sessions/{id}/config        update config (body: { model?, approval_policy?, ... })
```

### Session Actions

```
POST /api/sessions/{id}/messages       send message (body: { content, model?, effort? })
                                       → { accepted, row }           ← returns user ConversationRowEntry
POST /api/sessions/{id}/steer          steer turn (body: { content })
POST /api/sessions/{id}/interrupt      interrupt active turn
POST /api/sessions/{id}/compact        compact context
POST /api/sessions/{id}/undo           undo last turn
POST /api/sessions/{id}/rollback       rollback N turns (body: { num_turns })
```

### Approvals

All share response shape: `{ session_id, request_id, outcome, active_request_id, approval_version }`

```
POST /api/sessions/{id}/approve                approve/deny tool (body: { request_id, decision })
POST /api/sessions/{id}/answer                 answer question (body: { request_id, answer? })
POST /api/sessions/{id}/permissions/respond     grant/deny permissions (body: { request_id, permissions?, scope? })
```

### Server & Config

```
GET  /health                           → { status: "ok" }
GET  /api/models/claude                → { models: ClaudeModelOption[] }
GET  /api/models/codex                 → { models: CodexModelOption[] }
GET  /api/usage/claude                 → { usage?, error_info? }
GET  /api/usage/codex                  → { usage?, error_info? }
GET  /api/server/openai-key            → { configured }
POST /api/server/openai-key            store key (body: { key })
GET  /api/server/linear-key            → { configured }
POST /api/server/linear-key            store key (body: { key })
GET  /api/server/tracker-keys          → { linear: { configured, source }, ... }
```

### Worktrees

```
GET    /api/worktrees?repo_root=       → { repo_root, worktree_revision, worktrees[] }
POST   /api/worktrees                  create (body: { repo_path, branch_name, base_branch })
POST   /api/worktrees/discover         discover (body: { repo_path })
DELETE /api/worktrees/{id}?force=&delete_branch=   remove
```

### Missions

```
GET    /api/missions                   → { missions: MissionSummary[] }
GET    /api/missions/{id}              → { summary, issues[], settings, ... }
POST   /api/missions                   create (body: { name, repo_root, ... })
PUT    /api/missions/{id}              update metadata
DELETE /api/missions/{id}              delete
GET    /api/missions/{id}/issues       → MissionIssueItem[]
POST   /api/missions/{id}/issues/{issue_id}/retry   retry failed issue
POST   /api/missions/{id}/start-orchestrator         start polling
POST   /api/missions/{id}/dispatch     dispatch issue (body: { issue_identifier })
PUT    /api/missions/{id}/settings     update settings
```

### Response Patterns

```
Read:       { sessions: [...] } / { session: {...} } / { rows: [...] }
Mutation:   { accepted: true } or { ok: true }
Approval:   { session_id, request_id, outcome, approval_version }
Error:      { code: "string_code", error: "human message" }
```

---

## WebSocket Contract

### Client → Server Messages

JSON, discriminated on `type`, snake_case.

**Subscriptions:**
```jsonc
{ "type": "subscribe_list" }
{ "type": "subscribe_session", "session_id": "...", "include_snapshot": false }
{ "type": "unsubscribe_session", "session_id": "..." }
```

**Session interaction:**
```jsonc
{ "type": "send_message", "session_id": "...", "content": "...", "model?": "..." }
{ "type": "approve_tool", "session_id": "...", "request_id": "...", "decision": "approved" }
{ "type": "answer_question", "session_id": "...", "request_id": "...", "answer": "..." }
{ "type": "interrupt_session", "session_id": "..." }
{ "type": "end_session", "session_id": "..." }
```

### Server → Client Messages

**List-level** (after `subscribe_list`):

| Type | Key fields |
|------|------------|
| `session_created` | `session: SessionListItem` |
| `session_list_item_updated` | `session: SessionListItem` |
| `session_list_item_removed` | `session_id` |
| `session_ended` | `session_id, reason` |
| `session_forked` | `source_session_id, new_session_id` |

**Session-level** (after `subscribe_session`):

| Type | Key fields |
|------|------------|
| `conversation_rows_changed` | `session_id, upserted[], removed_row_ids[], total_row_count` |
| `session_delta` | `session_id, changes: StateChanges` |
| `approval_requested` | `session_id, request, approval_version` |
| `approval_decision_result` | `session_id, request_id, outcome, approval_version` |
| `tokens_updated` | `session_id, usage, snapshot_kind` |
| `context_compacted` | `session_id` |
| `undo_started` / `undo_completed` | `session_id, success?, message?` |
| `thread_rolled_back` | `session_id, num_turns` |
| `rate_limit_event` | `session_id, info` |

**Error:**
```jsonc
{ "type": "error", "code": "http_only_endpoint", "message": "..." }
```

---

## Wire Protocol

### Conversation Rows

Rows arrive as `RowEntrySummary` — each has `session_id`, `sequence`, `turn_id?`, and a `row` discriminated on `row_type`:

```
user, assistant, thinking, system, tool, activity_group,
question, approval, worker, plan, hook, handoff
```

Tool rows carry a `tool_display` object (server-computed). The client renders it verbatim — no tool-specific branching:
- `summary` — primary text
- `subtitle` — secondary text (file path, command)
- `glyph_symbol` — SF Symbol name (map to your icon set)
- `glyph_color` — semantic color name
- `right_meta` — badge text (duration, line count)
- `output_preview` — collapsed preview
- `diff_preview` — inline diff snippet
- `summary_font` — `"mono"` or `"system"`
- `display_tier` — `prominent | standard | compact | minimal`
- `subtitle_absorbs_meta` — when true, hide right_meta

Expanded content (full input/output/diff) is lazy-loaded via `GET /rows/{row_id}/content`.

### Key Enums (string constants)

- **Provider**: `claude`, `codex`
- **SessionStatus**: `active`, `ended`
- **WorkStatus**: `working`, `waiting`, `permission`, `question`, `reply`, `ended`
- **ToolFamily**: `shell`, `file_read`, `file_change`, `search`, `web`, `image`, `agent`, `question`, `approval`, `permission_request`, `plan`, `todo`, `config`, `mcp`, `hook`, `handoff`, `context`, `generic`
- **ToolStatus**: `pending`, `running`, `completed`, `failed`, `cancelled`, `blocked`, `needs_input`

### Unknown Variant Resilience

The codec must silently drop unknown `type`/`row_type` values (log a warning, return null). The WS connection must never crash on a new server type the client doesn't recognize.

---

## Store Reconciliation

REST and WS operate in parallel. Stores must handle race conditions.

**Session list**: REST replaces all; WS upserts/removes incrementally by session_id.

**Conversation**: REST bootstraps; WS applies `upserted` by row_id (insert or replace), removes by `removed_row_ids`, always sort by sequence.

**Approvals**: Track `approval_version` as a high water mark. Reject requests with version <= mark.

---

## UI Behavior

### Session List
- Group sessions by `repository_root || project_path`
- Sort groups by most recent activity
- Within groups: active sessions first, then by last_activity_at descending
- Show: status dot (colored by work_status), session name (custom_name > summary > first_prompt > truncated ID), provider badge, relative time

### Conversation View
- Scroll container with pin-to-bottom (auto-scroll on new rows when at bottom)
- "Jump to bottom" button when scrolled up
- Load older messages on scroll to top (pagination via before_sequence)
- User messages right-aligned in a bubble
- Assistant messages full-width with markdown rendering
- Tool cards with colored edge bar, click to expand (lazy-loads content)
- Thinking rows collapsible with preview when collapsed
- Streaming cursor on `is_streaming` rows

### Approval Banner
- Renders at top of session when approval is pending
- Type-specific UI:
  - `exec` — command preview + Allow/Deny
  - `patch` — file path + diff preview + Allow/Deny
  - `question` — option buttons + free text
  - `permissions` — permission list + Grant/Deny

### Session Header
- Status dot, session name, work status label, model badge
- Action buttons (visible when session is active): Interrupt, Undo, Compact, End

### Message Composer
- Auto-resize textarea
- Enter to send, Shift+Enter for newline
- Stop button when agent is working
- Disabled when session is ended

### Keyboard Navigation
- j/k or arrows: navigate session list
- Enter: open selected session
- Escape: back to dashboard

---

## Design Tokens

All colors, spacing, radii, and type scale defined as CSS custom properties. The theme is called "Cosmic Harbor" — dark backgrounds with cyan accents:

- Backgrounds: `#0F0E11`, `#151416`, `#1C1B1F`
- Text: 92% / 65% / 50% / 38% white opacity
- Accent: `#54AEE5` (cyan)
- Status: working (cyan), permission (coral), question (purple), reply (blue), ended (gray)
- Tool colors: bash (green), read (blue), write (orange), search (purple), etc.
- Spacing: 4pt base grid (2/4/8/12/16/24/32)
- Type scale: 9-24px
- Edge bar: 3px left accent

---

## Pitfalls

1. **WS doesn't deliver initial data.** Always fetch from REST first.
2. **`include_snapshot: true` errors.** Always false on subscribe_session.
3. **REST responses are wrapped.** `{ sessions: [] }` not bare `[]`.
4. **Rename is `PATCH /sessions/{id}/name`** not `/sessions/{id}`.
5. **Message endpoint is `/messages` (plural)** not `/message`.
6. **Dedup rows by row_id** when using REST sendMessage + WS delivery.
7. **Version-gate approvals.** Stale replays cause phantom banners.
8. **Don't fetch over WS.** Returns `http_only_endpoint` error.
