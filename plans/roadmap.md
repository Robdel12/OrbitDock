# OrbitDock Feature Parity Roadmap

> Goal: Make OrbitDock a fully capable Codex client you can actually develop apps with.
> Each phase is a shippable unit with Rust server changes + tests.
> macOS UI polish is a separate pass after the data layer works.

## Current State (what works today)

| Feature | Server | Swift UI |
|---------|--------|----------|
| Chat (send message, model/effort overrides) | Yes | Yes |
| Tool approvals (5 decision variants) | Yes | Yes |
| Question answering | Yes | Yes (needs verification) |
| Approval history + deletion | Yes | Yes |
| Autonomy level changes (approval_policy + sandbox_mode) | Yes | Yes |
| Session create/end/resume/rename/interrupt | Yes | Yes |
| Token usage tracking | Yes | Yes |
| Rate limiting (primary + secondary windows) | Yes | Yes |
| Thinking/reasoning display | Yes | Yes |
| Plan display | Yes (PlanUpdate events) | Exists (likely broken) |
| Diff display | Yes (TurnDiff events) | Exists (likely broken) |
| MCP bridge (HTTP API for pair-debugging) | Yes | N/A |
| Passive Codex session watching | Yes | Yes |

---

## Phase 1: Skills Management ✅

**Status**: Complete (commit `1d4bf42`)

### What was built

**Rust server** (protocol + connectors + server):
- [x] Protocol types: `SkillInput`, `SkillMetadata`, `SkillScope`, `SkillErrorInfo`, `SkillsListEntry`, `RemoteSkillSummary`
- [x] 3 client messages: `ListSkills`, `ListRemoteSkills`, `DownloadRemoteSkill`
- [x] 4 server messages: `SkillsList`, `RemoteSkillsList`, `RemoteSkillDownloaded`, `SkillsUpdateAvailable`
- [x] `SendMessage` expanded with `skills: Vec<SkillInput>` (serde default, skip_serializing_if empty)
- [x] Connector: 3 action methods + 4 event handlers + skills forwarded as `UserInput::Skill` items
- [x] Session: 3 `CodexAction` variants + 4 event broadcasts
- [x] WebSocket: 3 new client message handlers + skills passed through SendMessage
- [x] 4 protocol roundtrip tests (38 total pass)

**SwiftUI frontend**:
- [x] `ServerProtocol.swift`: 7 new types + 4 server message cases + 3 client message cases
- [x] `ServerConnection.swift`: 4 callbacks + routing + 3 convenience methods
- [x] `ServerAppState.swift`: `sessionSkills` state + callbacks + `listSkills` method
- [x] `SkillsPicker.swift` (new): Popover grouped by scope (repo/user/system/admin) with toggles
- [x] `CodexInputBar.swift`: Bolt icon + popover + badge + inline `$` completion

**Inline $ completion** (bonus, not in original plan):
- Type `$` to trigger filtered skill list above input bar
- Keyboard nav: arrow keys + Emacs C-n/C-p + Enter/Tab to accept + Escape to dismiss
- `$skill-name` token stays in message text for context
- Skills extracted on send and attached via skills array (combined with popover selections)
- Trailing punctuation handled (`$skill-name?` still matches)
- Bolt icon lights up when inline `$skills` detected

### Not implemented (deferred)
- [ ] MCP bridge endpoints for skills (lower priority, can use bolt icon or `$` inline)
- [ ] Remote skills download UI (server support exists, needs SwiftUI view)

---

## Phase 2: Context Compaction + Undo/Rollback ✅

**Status**: Complete

### What was built

**Rust server** (protocol + connectors + server):
- [x] 3 client messages: `CompactContext`, `UndoLastTurn`, `RollbackTurns`
- [x] 4 server messages: `ContextCompacted`, `UndoStarted`, `UndoCompleted`, `ThreadRolledBack`
- [x] Connector: 3 action methods (`compact`, `undo`, `thread_rollback`) + 4 event translations
- [x] Session: 3 `CodexAction` variants + dispatch + 4 event handlers with state transitions
- [x] WebSocket: 3 client message handlers (rollback validates `num_turns >= 1`)
- [x] Protocol roundtrip tests pass

**SwiftUI frontend**:
- [x] `ServerProtocol.swift`: 3 client + 4 server message types with manual Codable
- [x] `ServerConnection.swift`: 4 callbacks + routing + 3 convenience methods
- [x] `ServerAppState.swift`: `undoInProgress` state + 4 callbacks + 3 action methods
- [x] `SessionDetailView.swift`: Compact button (inline next to token badge) + Undo button in action bar
- [x] `ConversationView.swift`: "Roll back to here" pill on user messages — shows on all user messages where agent has responded, including the last turn

### Not implemented (deferred)
- [ ] MCP bridge endpoints (`/compact`, `/undo`, `/rollback`)
- [ ] Dedicated roundtrip tests for each operation (protocol serialization covered by existing tests)

---

## Phase 3: MCP Server Visibility ✅

**Status**: Complete (Rust + Swift done, tests/bridge deferred)

### What was built

**Rust server** (protocol + connectors + server):
- [x] 2 client messages: `ListMcpTools`, `RefreshMcpServers`
- [x] 3 server messages: `McpToolsList`, `McpStartupUpdate`, `McpStartupComplete`
- [x] Shared types: `McpStartupStatus`, `McpStartupFailure`, `McpAuthStatus`, `McpTool`, `McpResource`, `McpResourceTemplate`
- [x] Connector: 2 action methods + 3 event handlers (McpListToolsResponse, McpStartupUpdate, McpStartupComplete)
- [x] Session: 2 `CodexAction` variants + 3 event broadcasts
- [x] WebSocket: 2 client message handlers
- [x] Protocol roundtrip tests (3 new: McpToolsList, McpStartupUpdate, McpStartupComplete)

### Not implemented (deferred)
- [ ] MCP bridge endpoints (`GET /api/sessions/:id/mcp-tools`, `POST /api/sessions/:id/mcp-refresh`)
- [ ] Integration tests for MCP startup sequence

---

## Phase 4: Thread Forking ✅

**Status**: Complete

### What was built

**Rust server** (protocol + connectors + server):
- [x] `ClientMessage::ForkSession { source_session_id, nth_user_message?, model?, approval_policy?, sandbox_mode?, cwd? }`
- [x] `ServerMessage::SessionForked { source_session_id, new_session_id, forked_from_thread_id? }`
- [x] Connector: renamed `_thread_manager` → `thread_manager`, stored `codex_home: PathBuf`
- [x] Connector: extracted `build_config()` + `from_thread()` helpers to share between `new()` and `fork_thread()`
- [x] Connector: `fork_thread()` uses `find_thread_path_by_id_str` (same as app-server) to locate rollout path
- [x] Connector: `rollout_path()` + `codex_home()` accessors for loading forked messages
- [x] Session: `CodexAction::ForkSession` with oneshot reply channel for async result
- [x] Session: `forked_from_session_id` field with `set_forked_from()` setter, included in `state()` snapshots
- [x] WebSocket: `ForkSession` handler — forks thread, loads messages from rollout, persists to SQLite, creates new session
- [x] Persistence: `forked_from_session_id` in `SessionCreate`, `RestoredSession`, and session restoration
- [x] Migration `014_fork_origin.sql`: adds `forked_from_session_id` column
- [x] Protocol roundtrip tests: `test_fork_session_roundtrip`, `fork_session_minimal`, `test_session_forked_roundtrip`, `session_forked_without_thread_id`
- [x] All 50 tests pass (18 protocol + 32 server)

**SwiftUI frontend**:
- [x] `ServerProtocol.swift`: `forkSession` client message + `sessionForked` server message + `forkedFromSessionId` in snapshot
- [x] `ServerConnection.swift`: `onSessionForked` callback + `forkSession()` convenience method
- [x] `ServerAppState.swift`: `forkSession()` action + `forkInProgress` + `forkOrigins` dictionary populated from snapshots + live callbacks
- [x] `SessionDetailView.swift`: "Fork" button in codex action bar with progress spinner
- [x] `ConversationView.swift`: "Fork from here" pill on user messages + persistent `ForkOriginBanner` header (above scroll)
- [x] Fork badge (`ForkBadge`) shown in sidebar, dashboard (active + history), and quick switcher
- [x] `MCPBridge.swift`: `POST /api/sessions/:id/fork` endpoint

**MCP debug tool**:
- [x] `fork_session` tool in orbitdock-debug-mcp with `nth_user_message` support

### Design decisions
- Uses `find_thread_path_by_id_str` to locate rollout path (same approach as codex app-server)
- Fork action dispatched via oneshot channel so websocket handler can await the result and register the new session
- `from_thread()` helper avoids duplicating event loop setup between `new()` and `fork_thread()`
- Fork origin tracked via `forkOrigins: [String: String]` dictionary on `ServerAppState` (not per-session field) to survive session overwrites from `handleSessionCreated`
- Fork origin persists across restarts: SQLite → `RestoredSession` → `SessionHandle` → snapshot → Swift `forkOrigins`
- `ForkOriginBanner` placed above ScrollView as persistent header (not inside scroll content) so it's always visible
- "Fork from here" pills use accent color to differentiate from rollback pills (neutral)

### Not implemented (deferred)
- [ ] Integration tests requiring live codex-core

---

## Phase 5: Turn Steering

**Why**: Correct the agent mid-turn without losing work. "Actually, use postgres not sqlite" while it's still running.

### Investigation needed first
Our connector sends Ops via `CodexThread::submit(op)`. Need to verify:
1. Can we `submit(Op::UserInput { items })` while a turn is in progress?
2. Does it append to the current turn or start a new one?
3. Does codex-core handle this gracefully or do we need the app-server's `turn/steer` path?

- [ ] **Spike**: Test `submit(Op::UserInput)` during active turn in a throwaway Codex session

### Protocol layer (`crates/protocol`)
- [ ] Add `ClientMessage::SteerTurn { session_id, content: String }`

### Connector layer (`crates/connectors`)
- [ ] Add `steer(content)` action → sends `Op::UserInput { items: [UserInput::Text { text }] }`
- [ ] Validate turn is in progress before sending (or let codex-core reject it)

### Server layer (`crates/server`)
- [ ] `websocket.rs`: Handle `SteerTurn` client message
- [ ] Verify session has an active turn, return error if not
- [ ] `codex_session.rs`: Add `CodexAction::Steer`
- [ ] Track `is_turn_active` flag on `SessionHandle` (set on TurnStarted, cleared on TurnCompleted/TurnAborted)

### Tests
- [ ] `test_steer_turn_dispatches_input` - SteerTurn sends Op::UserInput to connector
- [ ] `test_steer_rejects_when_no_turn` - Error returned when no turn is active
- [ ] `test_steer_message_appears_in_stream` - Steered content shows up as a user message event

### MCP bridge
- [ ] `POST /api/sessions/:id/steer` → `{ content: "..." }`

---

## Phase 6: Rich Input (Images + Mentions)

**Why**: Can't paste screenshots or reference files. Important for debugging and providing context.

### UserInput types to support
- `UserInput::Image { image_url }` - base64 data URI
- `UserInput::LocalImage { path }` - local file path (codex-core converts to base64)
- `UserInput::Mention { name, path }` - explicit file/resource mention

### Protocol layer (`crates/protocol`)
- [ ] Expand `ClientMessage::SendMessage` with `images: Option<Vec<ImageInput>>` field
- [ ] Expand `ClientMessage::SendMessage` with `mentions: Option<Vec<MentionInput>>` field
- [ ] Add `ImageInput { input_type: String, value: String }` ("url" or "path")
- [ ] Add `MentionInput { name: String, path: String }`

### Connector layer (`crates/connectors`)
- [ ] Expand `send_message` to build `Vec<UserInput>` from all input types
- [ ] Map `ImageInput` with type "url" → `UserInput::Image { image_url }`
- [ ] Map `ImageInput` with type "path" → `UserInput::LocalImage { path }`
- [ ] Map `MentionInput` → `UserInput::Mention { name, path }`

### Tests
- [ ] `test_send_message_with_image_url` - Image URL becomes UserInput::Image
- [ ] `test_send_message_with_local_image` - Path becomes UserInput::LocalImage
- [ ] `test_send_message_with_mention` - Mention becomes UserInput::Mention
- [ ] `test_send_message_mixed_inputs` - Text + image + skill + mention all included correctly

### MCP bridge
- [ ] Expand `POST /api/sessions/:id/message` payload to accept `images` and `mentions`

---

## Phase 7: Review Mode

**Why**: Dedicated code review workflow. Lower priority than daily development features but important for real usage.

### codex-core mapping
| Op | EventMsg |
|----|----------|
| `Op::Review { review_request }` | `EnteredReviewMode(ReviewRequest)` |
| *(turn completes)* | `ExitedReviewMode(ReviewOutputEvent)` |

### ReviewTarget types
- `UncommittedChanges` - working tree (staged, unstaged, untracked)
- `BaseBranch { branch }` - compare current branch to base
- `Commit { sha, title? }` - review specific commit
- `Custom { instructions }` - free-form review prompt

### Protocol layer (`crates/protocol`)
- [ ] Add `ClientMessage::StartReview { session_id, target: ReviewTarget }`
- [ ] Add `ServerMessage::ReviewStarted { session_id, target: ReviewTarget }`
- [ ] Add `ServerMessage::ReviewCompleted { session_id, output: Option<ReviewOutput> }`
- [ ] Add `ReviewTarget` enum with 4 variants

### Connector layer (`crates/connectors`)
- [ ] Add `start_review(request)` action → sends `Op::Review`
- [ ] Handle `EventMsg::EnteredReviewMode` → `ConnectorEvent::ReviewStarted`
- [ ] Handle `EventMsg::ExitedReviewMode` → `ConnectorEvent::ReviewCompleted`

### Server layer (`crates/server`)
- [ ] `websocket.rs`: Handle `StartReview`, dispatch to connector
- [ ] `codex_session.rs`: Add `CodexAction::StartReview`
- [ ] `codex_session.rs`: Handle review events, broadcast to subscribers

### Tests
- [ ] `test_review_uncommitted_changes` - ReviewTarget::UncommittedChanges roundtrip
- [ ] `test_review_base_branch` - ReviewTarget::BaseBranch with branch name
- [ ] `test_review_commit` - ReviewTarget::Commit with sha
- [ ] `test_review_custom` - ReviewTarget::Custom with instructions
- [ ] `test_review_events_sequence` - ReviewStarted → messages → ReviewCompleted

### MCP bridge
- [ ] `POST /api/sessions/:id/review` → `{ target: { type: "uncommitted" | "branch" | "commit" | "custom", ... } }`

---

## Phase 8: Shell Commands + Custom Prompts + Misc

**Why**: Quality of life. One-off shell commands, custom prompts, elicitation, stream error handling.

### Features

**One-off shell command** (`Op::RunUserShellCommand { command }`)
Run a command through Codex's sandbox without starting a full turn. Output streams via normal `ExecCommand*` events.

**Custom prompts** (`Op::ListCustomPrompts` → `ListCustomPromptsResponse`)
List project-defined prompt templates.

**Elicitation** (`EventMsg::ElicitationRequest` + `Op::ResolveElicitation`)
Structured form input the agent requests (multiple-choice, text fields, etc.).

**Stream errors** (`EventMsg::StreamError` + `EventMsg::Warning`)
Surface model stream errors and non-fatal warnings to the client.

### Protocol layer (`crates/protocol`)
- [ ] Add `ClientMessage::RunShellCommand { session_id, command: String }`
- [ ] Add `ClientMessage::ListCustomPrompts { session_id }`
- [ ] Add `ClientMessage::ResolveElicitation { session_id, server_name: String, request_id: String, decision: ElicitationAction }` (Accept/Decline/Cancel)
- [ ] Add `ServerMessage::CustomPromptsList { session_id, prompts }`
- [ ] Add `ServerMessage::ElicitationRequested { session_id, request_id, ... }`
- [ ] Add `ServerMessage::StreamError { session_id, message, details: Option<String> }`
- [ ] Add `ServerMessage::Warning { session_id, message }`

### Connector layer (`crates/connectors`)
- [ ] Add `run_shell_command(command)` action → sends `Op::RunUserShellCommand`
- [ ] Add `list_custom_prompts()` action → sends `Op::ListCustomPrompts`
- [ ] Add `resolve_elicitation(server_name, request_id, decision)` action → sends `Op::ResolveElicitation`
- [ ] Handle `EventMsg::ElicitationRequest` → `ConnectorEvent::ElicitationRequested`
- [ ] Handle `EventMsg::StreamError` → `ConnectorEvent::StreamError`
- [ ] Handle `EventMsg::Warning` → `ConnectorEvent::Warning`

### Server layer (`crates/server`)
- [ ] `websocket.rs`: Handle `RunShellCommand`, `ListCustomPrompts`, `ResolveElicitation`
- [ ] `codex_session.rs`: Handle new connector events, broadcast to subscribers

### Tests
- [ ] `test_shell_command_dispatches_op` - RunShellCommand sends `Op::RunUserShellCommand`
- [ ] `test_custom_prompts_roundtrip` - ListCustomPrompts + response
- [ ] `test_elicitation_request_broadcast` - ElicitationRequested reaches subscribers
- [ ] `test_elicitation_resolve_roundtrip` - ResolveElicitation dispatches correct Op
- [ ] `test_stream_error_broadcast` - StreamError reaches subscribers
- [ ] `test_warning_broadcast` - Warning reaches subscribers

---

## Not Planned (out of scope)

| Feature | Reason |
|---------|--------|
| Authentication (login/logout) | Users auth via `codex` CLI first |
| Config read/write | Can use CLI or edit files directly |
| Collaboration modes | Experimental, low adoption |
| Feedback upload | Not blocking |
| Fuzzy file search | Only useful paired with file mention UI |
| Thread archiving | Session end is sufficient |
| DynamicToolCallRequest | Niche, client-side tool execution |

---

## Implementation Pattern (per feature)

Every feature follows this path through the codebase:

```
1. Protocol   → crates/protocol/src/     → ClientMessage + ServerMessage + types
2. Connector  → crates/connectors/src/   → action method (sends Op) + event handler (receives EventMsg)
3. Session    → crates/server/src/codex_session.rs → CodexAction variant + event → broadcast
4. WebSocket  → crates/server/src/websocket.rs     → client message → dispatch to session
5. Tests      → serialization roundtrip + dispatch + broadcast
6. MCP bridge → HTTP endpoint (Node.js + Swift MCPBridge)
7. Swift UI   → ServerProtocol + ServerAppState + view (separate pass)
```

## Verification Checklist (per phase)

- [ ] All new protocol types serialize/deserialize correctly (roundtrip tests)
- [ ] Connector dispatches correct codex-core Op for each client message
- [ ] Connector translates codex-core events to correct ConnectorEvents
- [ ] Server broadcasts events only to subscribed clients
- [ ] MCP bridge endpoints work (manual test with curl)
- [ ] `cargo test` passes with no warnings
- [ ] No regressions in existing functionality (run full test suite)

### Current test count: 50
### Target test count after all phases: ~80+
