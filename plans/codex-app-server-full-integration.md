# Codex Integration — Feature Plan

> What's built, what's next, and what we've learned.
> Verified against codex-core API surface (2026-02-07).

## Architecture (Current)

All Codex features flow through the Rust server with direct codex-core integration:

```
SwiftUI ←WebSocket→ Rust Server ←direct calls→ codex-core (library)
                         │
                    PersistenceWriter → SQLite
```

Key files:
- **Rust**: `crates/server/src/websocket.rs`, `codex_session.rs`, `persistence.rs`
- **Rust**: `crates/connectors/src/codex.rs` (CodexConnector)
- **Rust**: `crates/protocol/src/` (shared types)
- **Swift**: `Services/Server/ServerAppState.swift`, `ServerConnection.swift`, `ServerProtocol.swift`
- **Swift**: `Views/Codex/` (UI components)

---

## Done

### Session Management
- [x] Create sessions with model, approval_policy, sandbox_mode
- [x] Send messages, interrupt turns, end sessions
- [x] Resume ended sessions (loads from DB, starts fresh codex-core thread)
- [x] Session restoration on server startup
- [x] Hybrid session list: DB sessions (Claude) + server sessions (Codex) merged in ContentView

### Real-Time Updates
- [x] Streaming assistant messages (content deltas)
- [x] Tool execution events (exec commands, file patches, MCP calls)
- [x] Turn lifecycle (started, completed, aborted)
- [x] Session status transitions (working, waiting, permission, ended)

### Approvals
- [x] Exec approval (command execution) — approve/reject
- [x] Patch approval (file changes) — approve/reject
- [x] Question answering (user input requests)
- [x] Approval type tracking in session state for correct dispatch

### Token Usage & Rate Limits
- [x] Real-time token usage display (input/output/cached/context window)
- [x] `CodexTokenBadge` in session action bar
- [x] Codex rate limit tracking (`CodexUsageService`)
- [x] Usage gauge display

### Model Selection
- [x] Model picker in `NewCodexSessionSheet`
- [x] Model passed through `CreateSession` → codex-core config

### Plan & Diff Visualization
- [x] Plan updates streamed from codex-core → persisted in DB → displayed in `CodexTurnSidebar`
- [x] Unified diff updates streamed → `CodexDiffSidebar` with file-level stats
- [x] Toggle sidebar button in `codexActionBar` (shows "Plan" or "Changes")
- [x] `EditCard` with unified diff stats (+/- lines)

### Autonomy Control
- [x] `AutonomyPicker` — change approval_policy and sandbox_mode mid-session
- [x] `UpdateSessionConfig` protocol message for live changes
- [x] Autonomy level persisted across restarts (DB columns: approval_policy, sandbox_mode)

### Debugging
- [x] MCP debug bridge — Claude can control Codex sessions via `orbitdock-debug-mcp`
- [x] Structured JSON logging (`~/.orbitdock/logs/codex.log` and `server.log`)
- [x] Decode error logging with raw JSON payloads

---

## Next Up

### Session Naming
**API**: `thread/name/set`, `thread/name/updated` event

Let users name their sessions for easy identification. codex-core auto-generates names too (via `ThreadNameUpdated` event).

- Editable session name in sidebar / session header
- Auto-update when codex-core generates a name
- Persist in DB

**Scope**: Small — new protocol message + event, UI edit field.

**Files**: `protocol/client.rs`, `protocol/server.rs`, `websocket.rs`, `codex.rs` (handle `ThreadNameUpdated`), `ServerProtocol.swift`, `ServerAppState.swift`, sidebar session row

---

### Per-Turn Config Overrides
**API**: `turn/start` with `model`, `effort`, `sandbox_policy`, `personality`, `collaboration_mode`

Allow changing model/effort level per message without creating a new session.

codex-core's `TurnStartParams` accepts:
- `model: Option<String>` — override model for this turn and subsequent
- `effort: Option<ReasoningEffort>` — low/medium/high (for capable models)
- `sandbox_policy: Option<SandboxPolicy>` — override sandbox
- `personality: Option<Personality>` — override personality
- `collaboration_mode: Option<CollaborationMode>` — experimental preset

UI needs:
- Collapsible "advanced options" row above the input bar
- Model dropdown, effort picker
- Passed through to `SendMessage` → codex-core turn config

**Scope**: Extend `SendMessage` with optional config fields, add UI to `CodexInputBar`.

**Files**: `protocol/client.rs`, `websocket.rs`, `codex.rs`, `ServerProtocol.swift`, `CodexInputBar.swift`

---

### Context Compaction
**API**: `thread/compact/start`, `ContextCompacted` event

When sessions get long, let users (or auto-trigger) context compaction to summarize history.

- "Compact context" button in session actions
- Show compaction in progress indicator
- Update message count / context window after compaction

**Scope**: New protocol message, handle `ContextCompacted` event.

**Files**: `protocol/client.rs`, `websocket.rs`, `codex.rs`, `ServerProtocol.swift`, `SessionDetailView.swift`

---

### Turn Steer
**API**: `turn/steer` — add input to active turn (requires `expected_turn_id` precondition)

Let users send additional context while the agent is still working, instead of waiting for the turn to complete.

- When status is "working", input bar sends via steer instead of new turn
- Requires tracking current turn_id in session state

**Scope**: Medium — new protocol message, conditional send logic in input bar.

**Files**: `protocol/client.rs`, `websocket.rs`, `codex.rs`, `session.rs` (track turn_id), `ServerProtocol.swift`, `CodexInputBar.swift`

---

### MCP Server Status
**API**: `mcpServerStatus/list`, `McpStartupUpdate/Complete` events

Show connected MCP servers and their tools per session:
- Server name, connection state (connected/starting/failed)
- Tool count per server
- Error details for failed connections
- OAuth login initiation (`mcpServer/oauth/login`)

**Scope**: Add `McpStatusUpdated` event handling, new status view.

**Files**: `connectors/codex.rs`, `session.rs`, `server.rs` (protocol), `ServerAppState.swift`, new `MCPServerStatusView.swift`

---

### Thread Archive/Unarchive
**API**: `thread/archive`, `thread/unarchive`

Archive old sessions to reduce sidebar clutter, restore when needed.

- Archive action in session context menu
- "Archived Sessions" section or filter toggle in sidebar
- Unarchive action
- `thread/list` supports `archived` filter

**Scope**: New protocol messages, archive state in session, sidebar filter.

**Files**: `protocol/client.rs`, `websocket.rs`, `persistence.rs`, `ServerProtocol.swift`, `ServerAppState.swift`, `ContentView.swift`

---

### Thread Rollback
**API**: `thread/rollback` with `num_turns` — drops last N turns (does NOT revert file changes)

Undo turns when the agent goes in the wrong direction.

- Rollback button in session actions
- Preview of what will be removed
- Warning: "File changes are not reverted"
- Sync local message store after rollback (server returns updated thread)

**Scope**: New protocol message, message removal in ServerAppState, confirmation UI.

**Files**: `protocol/client.rs`, `websocket.rs`, `ServerProtocol.swift`, `ServerAppState.swift`, new `ThreadRollbackView.swift`

---

### Thread Fork
**API**: `thread/fork` with full config overrides (model, sandbox, instructions)

Branch a conversation to try alternative approaches without losing progress.

- Fork button in session actions
- Optional config overrides on the fork (different model, etc.)
- New session appears linked to parent
- Visual indicator of forked sessions

**Scope**: New protocol message, fork tracking in DB (forked_from column), UI for fork action.

**Files**: `protocol/client.rs`, `websocket.rs`, `persistence.rs` (new column), `ServerProtocol.swift`, `SessionDetailView.swift`

---

## Code Review Mode
**API**: `review/start` with ReviewTarget types

Run Codex as a code reviewer:
- `UncommittedChanges` — review working tree
- `BaseBranch { branch }` — review against a base branch
- `Commit { sha, title }` — review a specific commit
- `Custom { instructions }` — freeform review

Returns review findings as a turn with `review_thread_id`.

**Scope**: New protocol message, review target picker UI, display findings.

**Files**: `protocol/client.rs`, `websocket.rs`, `codex.rs`, `ServerProtocol.swift`, new `CodeReviewView.swift`

---

## Future Ideas

Lower priority — nice to have, verified as real APIs:

| Feature | API | Notes |
|---------|-----|-------|
| Skills Management | `skills/list`, `skills/config/write` | Discover, enable/disable skills |
| Remote Skills | `skills/remote/read/write` | Download community skills |
| Configuration UI | `config/read`, `config/value/write`, `config/batchWrite` | Edit Codex config from OrbitDock |
| Quick Command Exec | `command/exec` | Run single commands without a session, sandboxed |
| Collaboration Modes | `collaborationMode/list` | Experimental presets (pair programming, teaching, etc.) |
| Experimental Features | `experimentalFeature/list` | Toggle experimental flags |
| Collab Agent Tracking | `collabAgent/*` events | Sub-agent spawning/status visualization |
| Account Management | `account/read`, `account/login/*` | Show account status, initiate login |
| Thread Browsing | `thread/list`, `thread/read` | Browse all codex-core threads (not just OrbitDock sessions) |

---

## Lessons Learned

### Architecture wins
- **Direct codex-core integration** was the right call. No subprocess management, no IPC serialization, shared types. The "Phase 7" goal from the architecture plan turned out to be achievable from day one.
- **Rust server as intermediary** cleanly separates UI from business logic. Swift is purely reactive — receives state, sends actions.
- **Batched persistence** (50 commands / 100ms) handles high-throughput events without blocking the UI path.

### Gotchas
- **Ended sessions need DB fallback**: ContentView was filtering out ALL direct Codex sessions from DB, making ended sessions invisible. Fix: only filter out *active* direct Codex sessions (server handles those).
- **Resume creates a new codex-core thread**: Previous messages are visible in UI but the AI model starts fresh. This is a codex-core limitation — there's no way to restore context into a new thread.
- **`nonisolated(unsafe)` is necessary**: Swift suggests removing it from file-scope constants, but doing so causes `@MainActor` inference that cascades into 12+ warnings. Keep the annotation.
- **Approval type tracking matters**: exec vs patch approvals dispatch differently in codex-core. The server stores the approval type in session state so the correct handler is called.

### What we skipped
- **Actor pattern per session**: The plan called for `tokio::spawn` per session with mpsc channels. We use `Arc<Mutex<AppState>>` instead — simpler, works fine at current scale. Can revisit if we hit contention with 50+ sessions.
- **Claude connector in Rust**: The existing Swift path (hooks → CLI → SQLite → DatabaseManager) works well. No scaling issues. Unifying would mean rewriting all JSONL parsing and hook integration in Rust for minimal benefit.

---

*Created: 2025-01-20*
*Updated: 2026-02-07 — Rewritten for Rust server architecture. Verified against codex-core API surface.*
