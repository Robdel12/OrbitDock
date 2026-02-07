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

## Tasks

### 1. Session Naming
**API**: `thread/name/set`, `thread/name/updated` event

Let users name sessions. codex-core emits `ThreadNameUpdated` when names are set (manual only, no auto-generation).

#### Steps
- [x] **Rust connector**: Handle `ThreadNameUpdated` event in `codex.rs` → emit `ConnectorEvent::ThreadNameUpdated(name)`
- [x] **Rust session**: Store `custom_name: Option<String>` in `SessionHandle`, include in `SessionSummary` and `SessionState`
- [x] **Rust protocol**: Add `custom_name` to `SessionSummary`, `SessionState`, `StateChanges` — use `SessionDelta` for updates
- [x] **Rust protocol**: Add `RenameSession { session_id, name }` to `ClientMessage`
- [x] **Rust websocket**: Handle `RenameSession` → update handle, persist, broadcast delta, call codex-core `SetThreadName`
- [x] **Rust persistence**: Add `PersistCommand::SetCustomName` → `UPDATE sessions SET custom_name = ?`
- [x] **Swift protocol**: Add `customName` to summary/state/delta, add `renameSession` to `ClientToServerMessage`
- [x] **Swift state**: Handle name updates in `ServerAppState` (snapshot + delta), add `renameSession()` action
- [x] **Swift UI**: Name already flows through `Session.displayName` (customName > summary > firstPrompt > projectName)
- [x] **Swift UI**: `RenameSessionSheet` in `AgentListPanel` + `QuickSwitcher` routes through `serverState.renameSession()` for server sessions
- [x] **Bug fix**: ContentView dedup filters passive rollout-watcher sessions by thread ID (not just session ID)
- [x] Verify: manual renames persist and update UI, no duplicate sessions in sidebar

---

### 2. Per-Turn Config Overrides
**API**: `turn/start` accepts `model`, `effort`, `sandbox_policy`

Change model or effort level per message without creating a new session.

#### Steps
- [ ] **Rust protocol**: Extend `SendMessage` with optional fields: `model`, `effort`, `sandbox_policy`
- [ ] **Rust websocket**: Pass overrides through to `CodexAction::SendMessage`
- [ ] **Rust connector**: Apply overrides in `codex.rs` when calling `UserTurn` op
- [ ] **Swift protocol**: Extend `sendMessage` encode to include optional `model`, `effort`, `sandbox_policy`
- [ ] **Swift connection**: Extend `sendMessage()` with optional params
- [ ] **Swift state**: Extend `sendMessage()` to forward overrides
- [ ] **Swift UI**: Add collapsible config row above `CodexInputBar` (chevron toggle)
  - [ ] Model dropdown (populated from session's available models)
  - [ ] Effort picker (low / medium / high) — only show for models that support it
- [ ] **Swift UI**: Show current model in the config row as default selection
- [ ] Verify: sending with a different model actually uses that model (check token badge / response)

---

### 3. Context Compaction
**API**: `thread/compact/start`, `ContextCompacted` event

Summarize long conversations to free up context window.

#### Steps
- [ ] **Rust connector**: Handle `ContextCompacted` event → emit `ConnectorEvent::ContextCompacted`
- [ ] **Rust protocol**: Add `CompactSession { session_id }` to `ClientMessage`
- [ ] **Rust protocol**: Add `SessionCompacted { session_id }` to `ServerMessage` (or use `SessionDelta`)
- [ ] **Rust websocket**: Handle `CompactSession` → call codex-core `Compact` op
- [ ] **Rust session**: Update token usage after compaction event
- [ ] **Swift protocol**: Add `compactSession` and handle compacted response
- [ ] **Swift state**: Handle compaction — refresh token counts
- [ ] **Swift UI**: "Compact" button in session action bar or context menu
- [ ] **Swift UI**: Brief indicator when compaction is in progress
- [ ] Verify: compaction reduces context window usage, token badge updates

---

### 4. Turn Steer
**API**: `turn/steer` — inject input into an active turn

Send additional context while the agent is working instead of waiting.

#### Steps
- [ ] **Rust session**: Track `current_turn_id: Option<String>` — set on `TurnStarted`, clear on `TurnComplete/Aborted`
- [ ] **Rust protocol**: Add `SteerSession { session_id, content, expected_turn_id }` to `ClientMessage`
- [ ] **Rust websocket**: Handle `SteerSession` → call codex-core `turn/steer` op
- [ ] **Rust protocol**: Include `current_turn_id` in `SessionSnapshot` and `StateChanges`
- [ ] **Swift protocol**: Add `steerSession` case, include `turnId` in session delta handling
- [ ] **Swift state**: Track `currentTurnId` per session, expose `steerSession()` method
- [ ] **Swift UI**: When session is `working` and `currentTurnId` is set, input bar calls `steerSession` instead of `sendMessage`
- [ ] **Swift UI**: Visual indicator that input will steer (not start new turn) — e.g. placeholder text "Add to current turn..."
- [ ] Verify: steer message appears in conversation, agent incorporates it mid-turn

---

### 5. MCP Server Status
**API**: `mcpServerStatus/list`, `McpStartupUpdate`, `McpStartupComplete` events

Show connected MCP servers and their tool counts.

#### Steps
- [ ] **Rust connector**: Handle `McpStartupUpdate` and `McpStartupComplete` events → emit `ConnectorEvent::McpStatusUpdated`
- [ ] **Rust connector**: Handle `McpListToolsResponse` to capture tool lists
- [ ] **Rust session**: Store `mcp_servers: Vec<McpServerInfo>` in `SessionHandle`
- [ ] **Rust protocol**: Add `McpServerInfo` type (name, state, tool_count, error)
- [ ] **Rust protocol**: Add `McpStatusUpdated { session_id, servers }` to `ServerMessage`
- [ ] **Rust protocol**: Include MCP status in `SessionSnapshot`
- [ ] **Swift protocol**: Add `McpServerInfo` type and `mcpStatusUpdated` case
- [ ] **Swift state**: Store `mcpServers: [String: [McpServerInfo]]` per session
- [ ] **Swift UI**: MCP status indicator in session header (e.g. "3 MCP servers" pill)
- [ ] **Swift UI**: Expandable detail showing each server name, state, tool count, errors
- [ ] Verify: MCP servers show up after session creation, errors visible for failed servers

---

### 6. Thread Archive / Unarchive
**API**: `thread/archive`, `thread/unarchive`

Archive old sessions to declutter the sidebar.

#### Steps
- [ ] **Rust protocol**: Add `ArchiveSession { session_id }` and `UnarchiveSession { session_id }` to `ClientMessage`
- [ ] **Rust websocket**: Handle archive → call codex-core archive op, remove from active sessions, broadcast `SessionEnded` (or new `SessionArchived`)
- [ ] **Rust websocket**: Handle unarchive → load from DB, re-add to state, broadcast `SessionCreated`
- [ ] **Rust persistence**: Add `is_archived` column to sessions (or reuse existing), persist on archive/unarchive
- [ ] **Swift protocol**: Add `archiveSession` and `unarchiveSession` cases
- [ ] **Swift state**: Add `archiveSession()` and `unarchiveSession()` methods
- [ ] **Swift UI**: "Archive" action in session row context menu (right-click)
- [ ] **Swift UI**: Filter toggle in sidebar: "Show Archived" (off by default)
- [ ] **Swift UI**: Archived sessions show with dimmed style + "Unarchive" action
- [ ] Verify: archived sessions disappear from sidebar, reappear with toggle, unarchive restores them

---

### 7. Thread Rollback
**API**: `thread/rollback` with `num_turns` — drops last N turns (does NOT revert file changes)

Undo turns when the agent goes wrong.

#### Steps
- [ ] **Rust protocol**: Add `RollbackSession { session_id, num_turns }` to `ClientMessage`
- [ ] **Rust protocol**: Add `SessionRolledBack { session_id, remaining_messages }` to `ServerMessage` (or resend snapshot)
- [ ] **Rust websocket**: Handle rollback → call codex-core `ThreadRollback` op
- [ ] **Rust connector**: Handle `ThreadRolledBack` event → rebuild message list from codex-core state
- [ ] **Rust session**: Remove rolled-back messages from `SessionHandle`, notify subscribers with updated snapshot
- [ ] **Swift protocol**: Add `rollbackSession` case, handle `sessionRolledBack` response
- [ ] **Swift state**: On rollback response, replace message list for the session
- [ ] **Swift UI**: "Undo last turn" button in session action bar or context menu
- [ ] **Swift UI**: Confirmation dialog: "Undo last N turn(s)? File changes will NOT be reverted."
- [ ] **Swift UI**: Optional: turn count picker (1, 2, 3, or custom)
- [ ] Verify: messages removed from UI, new messages sent after rollback work correctly

---

### 8. Thread Fork
**API**: `thread/fork` with full config overrides

Branch a conversation to try alternatives.

#### Steps
- [ ] **Rust protocol**: Add `ForkSession { session_id, model, sandbox_mode, approval_policy }` to `ClientMessage`
- [ ] **Rust websocket**: Handle fork → call codex-core `thread/fork`, create new `SessionHandle` from forked thread
- [ ] **Rust websocket**: Broadcast `SessionCreated` for the forked session, send `SessionSnapshot` to requesting client
- [ ] **Rust persistence**: Add `forked_from_session_id` column to sessions table (migration 012)
- [ ] **Rust persistence**: Persist fork relationship on session create
- [ ] **Swift protocol**: Add `forkSession` case
- [ ] **Swift state**: Handle fork — new session appears in list, auto-navigate to it
- [ ] **Swift model**: Add `forkedFromSessionId` to Session model
- [ ] **Swift UI**: "Fork" button in session action bar or context menu
- [ ] **Swift UI**: Optional config override sheet (change model, sandbox for the fork)
- [ ] **Swift UI**: Visual indicator in sidebar showing fork relationship (indent or icon)
- [ ] Verify: forked session has parent's messages, new messages go to fork only

---

### 9. Code Review Mode
**API**: `review/start` with `ReviewTarget` (UncommittedChanges, BaseBranch, Commit, Custom)

Run Codex as a code reviewer — creates a review turn with findings.

#### Steps
- [ ] **Rust protocol**: Add `StartReview { session_id, target }` to `ClientMessage` with `ReviewTarget` enum
- [ ] **Rust protocol**: Define `ReviewTarget`: `UncommittedChanges`, `BaseBranch { branch }`, `Commit { sha }`, `Custom { instructions }`
- [ ] **Rust connector**: Add `CodexAction::StartReview` → call codex-core `Review` op
- [ ] **Rust connector**: Handle `EnteredReviewMode` / `ExitedReviewMode` events
- [ ] **Rust websocket**: Handle `StartReview` → forward to connector
- [ ] **Swift protocol**: Add `startReview` case with `ReviewTarget` enum
- [ ] **Swift state**: Add `startReview(sessionId:target:)` method
- [ ] **Swift UI**: "Review" button in session action bar
- [ ] **Swift UI**: Review target picker sheet:
  - [ ] "Uncommitted changes" (default)
  - [ ] "Compare to branch" with branch name input
  - [ ] "Specific commit" with SHA input
  - [ ] "Custom" with freeform instructions
- [ ] **Swift UI**: Review findings render as normal conversation messages
- [ ] Verify: review produces findings, different targets work correctly

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
