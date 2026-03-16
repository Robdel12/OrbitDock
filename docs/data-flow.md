# OrbitDock Data Flow Contract

## Principle

**WebSocket = lightweight event envelopes. REST = all content.**

WS carries only summary-weight data (no raw tool payloads):
- Session lifecycle events (created, ended, removed — small payloads)
- Incremental conversation row summaries (`RowEntrySummary` — metadata + `ToolDisplay`, no raw invocation/result)
- Approval requests (interactive, real-time)
- Session state deltas (work_status, custom_name, etc.)

REST carries:
- Session list (bulk)
- Conversation bootstrap (summary rows + session state via `RowPageSummary`)
- Conversation pages (pagination, also `RowPageSummary`)
- Expanded tool content on demand (`ServerRowContent` via `GET /rows/{id}/content`)
- All queries and mutations

---

## Wire Types (content tiering)

Two type hierarchies enforce the contract at compile time:

| Layer | Rust Type | Swift Type | Contains raw payloads? |
|-------|-----------|------------|----------------------|
| **Internal/persistence** | `ConversationRowEntry` → `ConversationRow` → `ToolRow` | — | Yes (`invocation`, `result`) |
| **Wire (WS + HTTP)** | `RowEntrySummary` → `ConversationRowSummary` → `ToolRowSummary` | `ServerConversationRowEntry` → `ServerConversationRow` → `ServerConversationToolRow` | No. `tool_display: ToolDisplay` required. |
| **On-demand content** | `RowContentResponse` | `ServerRowContent` | Full `input_display`, `output_display`, `diff_display` |

### ToolRowSummary (wire-safe tool row)
Same fields as `ToolRow` except:
- **No** `invocation` (raw JSON input)
- **No** `result` (raw JSON output)
- `tool_display: ToolDisplay` is **required** (not optional)

Conversion: `ToolRow::to_summary()` strips payloads and guarantees `tool_display`.

### RowEntrySummary (wire-safe entry)

| Field | Type | Purpose |
|-------|------|---------|
| `session_id` | String | Owning session |
| `sequence` | u64 | Monotonic position within session (0-indexed) |
| `turn_id` | Option\<String\> | Groups rows into turns |
| `row` | ConversationRowSummary | Variant: User, Assistant, Thinking, Tool (summary), System, etc. |

**Identity:** `row.id` (each variant has an `id: String` field).
**Ordering:** `sequence` is authoritative. Assigned by the server on creation.

### RowPageSummary (wire-safe page)

Used by HTTP bootstrap, HTTP pagination, and WS `ConversationBootstrap`.

| Field | Type |
|-------|------|
| `rows` | Vec\<RowEntrySummary\> |
| `total_row_count` | u64 |
| `has_more_before` | bool |
| `oldest_sequence` | Option\<u64\> |
| `newest_sequence` | Option\<u64\> |

### Sequence Numbers
- 0-indexed, monotonic, gap-free within a session
- Assigned at row creation time: `last_row.sequence + 1`
- Never reused (rows are append-only; upserts preserve existing sequence)
- **Source of truth for pagination:** `has_more_before = oldest_loaded_sequence > 0`

### Row Count
- **Derived, never tracked as a counter.** The total row count is:
  - In-memory: `rows.len()` (the retained window, max 200)
  - For pagination: `newest_sequence + 1` (sequences are 0-indexed)
- No `total_row_count` counter that can inflate independently
- REST pagination uses sequence math: `newest_sequence + 1` for total,
  `oldest_sequence > 0` for `has_more_before`

---

## Server Architecture

### Row Lifecycle (3 paths, all converge at SessionHandle)

**Path 1: Transition State Machine (Codex + Claude direct)**
```
ConnectorEvent::RowCreated(entry)
  → transition() pure function
  → Effect::Persist(RowAppend { entry })         // full ConversationRowEntry to SQLite
  → Effect::Emit(ConversationRowsChanged { upserted: [entry.to_summary()] })  // summary to WS
  → dispatch_transition_input() applies state + broadcasts
```
Sequence assigned in transition: `rows.last().sequence + 1`

**Path 2: Transcript Sync (Claude hooks)**
```
Hook POST /api/hook
  → sync_transcript_messages()
  → plan_transcript_sync() (ID-based comparison via newest_synced_row_id)
  → AddRowAndBroadcast (new) / UpsertRowAndBroadcast (updated) / ReplaceRows (force resync)
```
Sequence assigned in SessionHandle::add_row()

**Path 3: REST Bootstrap (client request)**
```
GET /api/sessions/{id}/conversation?limit=50
  → conversation_bootstrap() reads from retained rows
  → Converts to RowPageSummary via .to_summary()
  → Returns ConversationBootstrapResponse with pagination metadata
```
Read-only. No mutations.

### SessionHandle (in-memory state owner)

**Retained window:** Last 200 rows in `Vec<ConversationRowEntry>` (full rows with raw payloads).
Older rows are evicted by `trim_retained_rows()` but remain in SQLite.

**Key invariants:**
- `rows` is always sorted by sequence
- `add_row()` appends and assigns sequence. Increments unread count.
- `upsert_row()` replaces by ID if found in retained window.
  If the row was evicted (not in window), appends without inflating count.
- `replace_rows()` replaces all rows (force resync). Broadcasts the result.
- `newest_synced_row_id` tracks the last row synced from transcript (ID-based).
- **Broadcast always converts to summary:** `entry.to_summary()` before serialization

### Broadcast Rules

Every mutation that changes conversation state MUST broadcast
`ConversationRowsChanged` with `Vec<RowEntrySummary>` (never full rows):

| Command | Broadcasts? | What |
|---------|-------------|------|
| `AddRowAndBroadcast` | Yes | Single new row (summary) |
| `UpsertRowAndBroadcast` | Yes | Single updated row (summary) |
| `ReplaceRows` | Yes | ALL rows (summaries, force resync recovery) |
| `AddRow` (no broadcast) | No | Internal use only |

Broadcast includes `total_row_count` derived from `newest_sequence + 1`.

### Event Log + Replay

- Ring buffer of last 1000 serialized events with revision numbers
- Events stored as pre-serialized JSON (already summary format — no raw payloads)
- `replay_since(revision)` returns events newer than client's revision
- If gap > 1000: returns None → subscribe handler falls back to snapshot
- Client should always have HTTP bootstrap as backup

---

## Client Architecture

### ServerConnection (unified WS + HTTP gate)

**One URLSession per transport, reused across reconnects.** Only the
`URLSessionWebSocketTask` is recreated on reconnect.

```
init() → create URLSession (once)
attemptConnect() → create WebSocketTask (per attempt), cancel old task
disconnect() → cancel task, keep URLSession alive
```

HTTP requests are gated on WS connection status — if WS is disconnected, HTTP throws `.serverUnreachable`.

### SessionStore (per-endpoint orchestrator)

**Subscription flow (atomic, sequential):**
```
subscribeToSession(sessionId)
  1. await HTTP bootstrap (REST) → RowPageSummary
  2. Extract sinceRevision from bootstrap
  3. WS subscribeSession(sinceRevision) — incremental from that point
```
Steps 1-3 run in a single Task. No parallel race.

**Reconnect flow (serialized, not parallel):**
```
handleConnectionStatusChanged(.connected)
  1. Clear stale lastRevision dictionary
  2. REST fetch sessions list (one call)
  3. For each subscribed session, SEQUENTIALLY:
     a. HTTP bootstrap
     b. WS subscribe with bootstrap revision
```
One Task iterates sessions. Not N parallel Tasks.

### ConversationStore (per-session conversation state)

**Data structures:**
- `messages: [TranscriptMessage]` — client-constructed from row summaries, sorted by sequence
- `rowEntries: [ServerConversationRowEntry]` — decoded wire entries for timeline view
- `hasMoreHistoryBefore: Bool` — set by server, derived from sequences
- `oldestLoadedSequence` / `newestLoadedSequence` — bounds of loaded data

**TranscriptMessage** is a client-only view model. It has NO raw tool payload fields
(`toolInput`, `rawToolInput`, `toolOutput` were removed). Tool rendering reads from
`toolDisplay` (always present on tool rows from the wire).

**Key invariants:**
- Deduplication by row ID (existing row → merge in-place, new row → insert-sort)
- `totalMessageCount` is SET from server value, never ratcheted with `max()`
- `hydrationState` derived from `hasMoreHistoryBefore`, not count comparison
- Live updates use binary-search insert (O(log n)), not full sort (O(n log n))
- Bootstrap/pagination uses full sort (runs once per bulk load, acceptable)

**Pagination:**
```
loadOlderMessages()
  → REST GET /api/sessions/{id}/conversation?before_sequence=X&limit=50
  → Server returns RowPageSummary from SQLite (rows beyond retained window)
  → Client extends oldestLoadedSequence downward
  → Terminates when hasMoreHistoryBefore == false (sequence-based)
```

### Expanded Tool Content (on-demand)

When a user expands a tool card, content is fetched via REST:
```
GET /api/sessions/{id}/rows/{rowId}/content
  → Returns ServerRowContent { inputDisplay, outputDisplay, diffDisplay, language }
  → Cached in TimelineRowStateStore.fetchedContent[rowId]
```
This is the only path that accesses full tool invocation/result data (read from SQLite on the server).

---

## Scale Path (100+ agents)

Summary-weight row events (~1-2 KB per tool) work well at current scale.
When we hit bandwidth pressure with 100+ streaming agents, the evolution is:

1. Replace `ConversationRowsChanged` with `ConversationRowsHint { session_id, newest_sequence }`
2. Client batches hints over 100ms window, fetches changed rows via REST
3. Streaming deltas (assistant text in-progress) stay on WS — latency-sensitive

This is a protocol change, not a migration. When we do it, the hint
message type replaces the current summary payload type.
