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

## Phase 1: Skills Management

**Why first**: Can't effectively use Codex without skills. This is the #1 blocker for real development work.

### codex-core mapping
| Op | EventMsg |
|----|----------|
| `Op::ListSkills { cwds, force_reload }` | `ListSkillsResponse { skills, errors }` |
| `Op::ListRemoteSkills` | `ListRemoteSkillsResponse { skills }` |
| `Op::DownloadRemoteSkill { hazelnut_id, is_preload }` | `RemoteSkillDownloaded { id, name, path }` |
| *(server-initiated)* | `SkillsUpdateAvailable` |

### Protocol layer (`crates/protocol`)
- [ ] Add `ClientMessage::ListSkills { session_id, cwds: Vec<String>, force_reload: bool }`
- [ ] Add `ClientMessage::ListRemoteSkills { session_id }`
- [ ] Add `ClientMessage::DownloadRemoteSkill { session_id, hazelnut_id: String }`
- [ ] Add `ServerMessage::SkillsList { session_id, skills, errors }`
- [ ] Add `ServerMessage::RemoteSkillsList { session_id, skills }`
- [ ] Add `ServerMessage::RemoteSkillDownloaded { session_id, id, name, path }`
- [ ] Add `ServerMessage::SkillsUpdateAvailable { session_id }`
- [ ] Add shared types: `SkillsListEntry`, `SkillMetadata`, `SkillScope`, `SkillErrorInfo`, `RemoteSkillSummary`
- [ ] Expand `ClientMessage::SendMessage` with `skills?: Vec<SkillInput>` field
- [ ] Add `SkillInput { name: String, path: String }` type

### Connector layer (`crates/connectors`)
- [ ] Add `list_skills(cwds, force_reload)` action → sends `Op::ListSkills`
- [ ] Add `list_remote_skills()` action → sends `Op::ListRemoteSkills`
- [ ] Add `download_remote_skill(id, is_preload)` action → sends `Op::DownloadRemoteSkill`
- [ ] Handle `EventMsg::ListSkillsResponse` → `ConnectorEvent::SkillsList`
- [ ] Handle `EventMsg::ListRemoteSkillsResponse` → `ConnectorEvent::RemoteSkillsList`
- [ ] Handle `EventMsg::RemoteSkillDownloaded` → `ConnectorEvent::RemoteSkillDownloaded`
- [ ] Handle `EventMsg::SkillsUpdateAvailable` → `ConnectorEvent::SkillsUpdateAvailable`
- [ ] Expand `send_message` to include `UserInput::Skill { name, path }` when skills are provided

### Server layer (`crates/server`)
- [ ] `websocket.rs`: Handle `ListSkills`, `ListRemoteSkills`, `DownloadRemoteSkill` client messages
- [ ] `websocket.rs`: Parse `skills` field from `SendMessage` and pass to connector
- [ ] `codex_session.rs`: Add `CodexAction` variants: `ListSkills`, `ListRemoteSkills`, `DownloadRemoteSkill`
- [ ] `codex_session.rs`: Handle 4 new connector events, broadcast to subscribers

### Tests
- [ ] `test_list_skills_roundtrip` - Client sends ListSkills, verify connector receives `Op::ListSkills`
- [ ] `test_list_remote_skills_roundtrip` - Same for remote skills
- [ ] `test_download_remote_skill_roundtrip` - Download triggers correct Op with hazelnut_id
- [ ] `test_skills_response_broadcast` - SkillsList event reaches only subscribed clients
- [ ] `test_skills_update_notification` - SkillsUpdateAvailable broadcasts correctly
- [ ] `test_send_message_with_skill` - Skill input items are included in UserTurn's items vec

### MCP bridge
- [ ] `GET /api/sessions/:id/skills` → list skills for session
- [ ] `GET /api/sessions/:id/skills/remote` → list remote skills
- [ ] `POST /api/sessions/:id/skills/download` → `{ hazelnut_id: "..." }`

---

## Phase 2: Context Compaction + Undo/Rollback

**Why**: Running out of context window is a constant problem. Need to compact manually and undo bad turns without starting over.

### codex-core mapping
| Op | EventMsg |
|----|----------|
| `Op::Compact` | `ContextCompacted` (+ normal turn events during summarization) |
| `Op::Undo` | `UndoStarted { message? }` → `UndoCompleted { success, message? }` |
| `Op::ThreadRollback { num_turns }` | `ThreadRolledBack { num_turns }` |

### How each works
- **Compact**: Starts a summarization turn. The summary replaces older context. Normal turn events fire (TurnStarted, AgentMessage, TurnComplete) plus `ContextCompacted`.
- **Undo**: Reverses the last turn's filesystem changes AND removes it from context. Two-event sequence.
- **Rollback**: Drops N turns from in-memory context only. Does NOT revert filesystem changes.

### Protocol layer (`crates/protocol`)
- [ ] Add `ClientMessage::CompactContext { session_id }`
- [ ] Add `ClientMessage::Undo { session_id }`
- [ ] Add `ClientMessage::RollbackThread { session_id, num_turns: u32 }`
- [ ] Add `ServerMessage::ContextCompacted { session_id }`
- [ ] Add `ServerMessage::UndoStarted { session_id, message: Option<String> }`
- [ ] Add `ServerMessage::UndoCompleted { session_id, success: bool, message: Option<String> }`
- [ ] Add `ServerMessage::ThreadRolledBack { session_id, num_turns: u32 }`

### Connector layer (`crates/connectors`)
- [ ] Add `compact()` action → sends `Op::Compact`
- [ ] Add `undo()` action → sends `Op::Undo`
- [ ] Add `rollback(num_turns)` action → sends `Op::ThreadRollback`
- [ ] Handle `EventMsg::ContextCompacted` → `ConnectorEvent::ContextCompacted`
- [ ] Handle `EventMsg::UndoStarted` → `ConnectorEvent::UndoStarted`
- [ ] Handle `EventMsg::UndoCompleted` → `ConnectorEvent::UndoCompleted`
- [ ] Handle `EventMsg::ThreadRolledBack` → `ConnectorEvent::ThreadRolledBack`

### Server layer (`crates/server`)
- [ ] `websocket.rs`: Handle `CompactContext`, `Undo`, `RollbackThread` client messages
- [ ] `codex_session.rs`: Add `CodexAction` variants: `Compact`, `Undo`, `Rollback`
- [ ] `codex_session.rs`: Handle 4 new connector events, broadcast to subscribers

### Tests
- [ ] `test_compact_roundtrip` - CompactContext dispatches `Op::Compact`
- [ ] `test_compact_event_broadcast` - ContextCompacted reaches subscribers
- [ ] `test_undo_roundtrip` - Undo dispatches `Op::Undo`
- [ ] `test_undo_events_sequence` - UndoStarted followed by UndoCompleted broadcasts correctly
- [ ] `test_rollback_roundtrip` - RollbackThread dispatches `Op::ThreadRollback` with correct num_turns
- [ ] `test_rollback_event_broadcast` - ThreadRolledBack reaches subscribers with turn count
- [ ] `test_rollback_zero_turns_rejected` - Edge case: num_turns=0 returns error

### MCP bridge
- [ ] `POST /api/sessions/:id/compact` → trigger compaction
- [ ] `POST /api/sessions/:id/undo` → undo last turn
- [ ] `POST /api/sessions/:id/rollback` → `{ num_turns: N }`

---

## Phase 3: MCP Server Visibility

**Why**: Need to see what MCP tools are connected, which servers are healthy, and refresh them. When MCP servers are your development tools, this is critical.

### codex-core mapping
| Op | EventMsg |
|----|----------|
| `Op::ListMcpTools` | `McpListToolsResponse { tools, resources, resource_templates, auth_statuses }` |
| `Op::RefreshMcpServers { config }` | `McpStartupUpdate` / `McpStartupComplete` sequence |
| *(server-initiated on session start)* | `McpStartupUpdate { server, status }` |
| *(server-initiated on session start)* | `McpStartupComplete { ready, failed, cancelled }` |

### Protocol layer (`crates/protocol`)
- [ ] Add `ClientMessage::ListMcpTools { session_id }`
- [ ] Add `ClientMessage::RefreshMcpServers { session_id }` (server passes empty `McpServerRefreshConfig` to codex-core — config re-read from disk)
- [ ] Add `ServerMessage::McpToolsList { session_id, tools, resources, auth_statuses }`
- [ ] Add `ServerMessage::McpStartupUpdate { session_id, server, status }`
- [ ] Add `ServerMessage::McpStartupComplete { session_id, ready, failed, cancelled }`
- [ ] Add shared types: `McpStartupStatus`, `McpStartupFailure`, `McpAuthStatus`, `McpTool`, `McpResource`

### Connector layer (`crates/connectors`)
- [ ] Add `list_mcp_tools()` action → sends `Op::ListMcpTools`
- [ ] Add `refresh_mcp_servers()` action → sends `Op::RefreshMcpServers`
- [ ] Handle `EventMsg::McpListToolsResponse` → `ConnectorEvent::McpToolsList`
- [ ] Handle `EventMsg::McpStartupUpdate` → `ConnectorEvent::McpStartupUpdate`
- [ ] Handle `EventMsg::McpStartupComplete` → `ConnectorEvent::McpStartupComplete`

### Server layer (`crates/server`)
- [ ] `websocket.rs`: Handle `ListMcpTools`, `RefreshMcpServers` client messages
- [ ] `codex_session.rs`: Add `CodexAction` variants: `ListMcpTools`, `RefreshMcpServers`
- [ ] `codex_session.rs`: Handle 3 new connector events, broadcast to subscribers
- [ ] Handle `McpStartupUpdate`/`McpStartupComplete` during initial session creation (fires on startup too)

### Tests
- [ ] `test_list_mcp_tools_roundtrip` - ListMcpTools dispatches correct Op
- [ ] `test_mcp_tools_response_broadcast` - McpToolsList with tools + auth reaches subscribers
- [ ] `test_refresh_mcp_servers_roundtrip` - RefreshMcpServers dispatches Op
- [ ] `test_mcp_startup_update_broadcast` - McpStartupUpdate events reach subscribers
- [ ] `test_mcp_startup_complete_broadcast` - McpStartupComplete with ready/failed/cancelled
- [ ] `test_mcp_auth_status_serialization` - All McpAuthStatus variants serialize correctly

### MCP bridge
- [ ] `GET /api/sessions/:id/mcp-tools` → list MCP tools, resources, auth status
- [ ] `POST /api/sessions/:id/mcp-refresh` → refresh MCP servers

---

## Phase 4: Thread Forking

**Why**: Branch a conversation to explore alternatives without losing the original. Essential for iterative development where you want to try different approaches.

### How it works in codex-core

`ThreadManager::fork_thread(nth_user_message, config, rollout_path)` is already accessible from our connector. It:
1. Reads the rollout history from the source thread's file
2. Truncates at `nth_user_message` (use `usize::MAX` for full history)
3. Spawns a new thread with that history as `InitialHistory::Forked`
4. The new thread gets a fresh `ThreadId` and its own rollout file
5. `SessionConfiguredEvent.forked_from_id` is set to the source thread's ID

### Important: `_thread_manager` is already on `CodexSession`
The connector already stores `_thread_manager: Arc<ThreadManager>` (prefixed with `_` because it's unused). Just rename it to `thread_manager` and call `fork_thread()`. No new dependencies needed.

### Rollout path
`SessionConfiguredEvent` (fired on session creation) includes `rollout_path`. We don't currently capture this — the connector's `translate_event()` doesn't match `EventMsg::SessionConfigured`. Need to store it on the session struct so fork can read it later.

### Protocol layer (`crates/protocol`)
- [ ] Add `ClientMessage::ForkSession { session_id, nth_user_message: Option<u32>, model: Option<String>, approval_policy: Option<String>, sandbox_mode: Option<String>, cwd: Option<String> }`
- [ ] Add `ServerMessage::SessionForked { original_session_id, new_session_id, forked_from_id }`

### Connector layer (`crates/connectors`)
- [ ] Rename `_thread_manager` → `thread_manager` on `CodexSession`
- [ ] Handle `EventMsg::SessionConfigured` to capture `rollout_path` on the session
- [ ] Add `fork(nth_user_message, config, rollout_path)` method → calls `thread_manager.fork_thread()`
- [ ] Return a new `CodexSession` (same flow as `create_session` but with forked history)

### Server layer (`crates/server`)
- [ ] `websocket.rs`: Handle `ForkSession` client message
- [ ] Look up source session's rollout path and config from `SessionHandle`
- [ ] Call connector fork (similar flow to `CreateSession` but with history)
- [ ] Register new session in AppState, start event loop
- [ ] Send `SessionForked` to requesting client
- [ ] Send `SessionCreated` to all list subscribers
- [ ] Store `rollout_path` on `SessionHandle` (if not already stored)

### Tests
- [ ] `test_fork_session_creates_new_session` - Fork produces a new session with unique ID
- [ ] `test_fork_session_broadcasts_created` - SessionCreated event sent to list subscribers
- [ ] `test_fork_session_inherits_config` - New session has source session's model/policy/cwd
- [ ] `test_fork_session_with_overrides` - Model/policy overrides apply to forked session
- [ ] `test_fork_session_source_not_found` - Error when source session_id doesn't exist
- [ ] `test_fork_session_at_turn` - nth_user_message truncates history correctly
- [ ] `test_fork_preserves_forked_from_id` - SessionConfigured has forked_from_id set

### MCP bridge
- [ ] `POST /api/sessions/:id/fork` → `{ nth_user_message?: N, model?: "...", approval_policy?: "...", sandbox_mode?: "...", cwd?: "..." }`

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

### Current test count: ~32
### Target test count after all phases: ~80+
