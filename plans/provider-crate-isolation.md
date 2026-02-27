# Provider Crate Isolation

> Decouple Claude and Codex provider logic from the server crate so that working on one provider never recompiles the other, and the server becomes a provider-agnostic orchestrator.

---

## Why We Are Doing This

The server binary can't compile without Codex even if you only want Claude. Provider-specific session management, auth, and file watching live in `crates/server/` with deep tentacles into server internals (SessionRegistry, PersistCommand, transition state machine). This means:

- Every `make rust-build` pulls in codex-core's heavy git dep + patched tungstenite forks
- Provider logic is tangled with orchestration logic — hard to reason about boundaries
- Adding a third provider means touching server internals instead of just registering a new crate

### Current State (after connector-core + per-provider split)

```
server/
├── claude_session.rs    (595 lines)  ← Claude event loop, deeply coupled to server
├── codex_session.rs     (921 lines)  ← Codex event loop, deeply coupled to server
├── codex_auth.rs        (272 lines)  ← Codex OAuth, uses broadcast channel
├── rollout_watcher.rs   (2646 lines) ← FSEvents watcher, EXTREME coupling to server
├── session.rs                        ← SessionHandle (shared state)
├── session_actor.rs                  ← Actor loop
├── session_command.rs                ← SessionCommand enum
├── transition.rs                     ← State machine (shared by both providers)
├── persistence.rs                    ← PersistCommand channel
└── state.rs                          ← SessionRegistry (global app state)

connector-claude/src/lib.rs           ← Protocol parsing only (clean)
connector-codex/src/lib.rs            ← Protocol parsing only (clean)
connector-core/src/lib.rs             ← ConnectorEvent, ConnectorError, ApprovalType
```

### Target State

```
server/
├── session.rs                        ← SessionHandle (unchanged)
├── session_actor.rs                  ← Actor loop (provider-agnostic)
├── session_command.rs                ← SessionCommand enum (unchanged)
├── transition.rs                     ← State machine (shared, maybe in connector-core)
├── persistence.rs                    ← PersistCommand channel (unchanged)
└── state.rs                          ← SessionRegistry (unchanged)

connector-claude/
├── src/lib.rs                        ← Protocol parsing (existing)
└── src/session.rs                    ← ClaudeSession + ClaudeAction (from server)

connector-codex/
├── src/lib.rs                        ← Protocol parsing (existing)
├── src/session.rs                    ← CodexSession + CodexAction (from server)
├── src/auth.rs                       ← CodexAuthService (from server)
└── src/rollout_watcher.rs            ← Passive session watcher (from server)

connector-core/
├── src/lib.rs                        ← Re-exports
├── src/event.rs                      ← ConnectorEvent (existing)
├── src/error.rs                      ← ConnectorError (existing)
└── src/session_loop.rs               ← handle_session_command (shared logic)
```

---

## The 5 Coupling Mechanisms

Every provider file in the server reaches into these shared systems. Understanding them is the key to a clean split.

### 1. SessionRegistry (`state.rs`)

Both sessions and rollout_watcher hold `Arc<SessionRegistry>` and call methods like `add_session()`, `remove_session()`, `broadcast_to_list()`, `register_claude_thread()`, `is_managed_codex_thread()`.

**Strategy:** Pass callbacks/closures instead of `Arc<SessionRegistry>`. The session loop doesn't need the full registry — it needs "remove me on exit" and "register my thread ID".

### 2. PersistCommand channel

`codex_session.rs`, `claude_session.rs`, and `rollout_watcher.rs` all send `PersistCommand` variants directly over `mpsc::Sender<PersistCommand>`.

**Strategy:** Keep the channel pattern but define provider-specific persist commands in each connector crate, then map them to `PersistCommand` at the server boundary. Or accept that PersistCommand is a server concern and pass the sender as a generic channel.

### 3. Transition state machine (`transition.rs`)

Both `codex_session.rs` and `claude_session.rs` call `transition::transition(state, input, &now)` and handle `Effect::Persist` / `Effect::Emit` results.

**Strategy:** Move `transition.rs` (or its core types `Input`, `Effect`) to `connector-core`. The state machine is provider-agnostic — it maps `ConnectorEvent` → state changes. Both providers just feed it events.

### 4. SessionCommand channel

`rollout_watcher.rs` sends `SessionCommand` variants to actor handles. Sessions receive commands through their actor loop.

**Strategy:** SessionCommand stays in the server. The rollout watcher emits parsed events; the server dispatches commands. This is the hardest seam to cut cleanly.

### 5. `handle_session_command` (shared function)

Currently in `codex_session.rs` but **called by both Claude and Codex sessions**. Handles `SendMessage`, `Approve`, `Interrupt`, `Steer`, etc.

**Strategy:** Move to `connector-core` as shared session loop infrastructure. It depends on `SessionHandle` + `PersistCommand` + transition, so those need to be accessible too.

---

## Phase 1: Extract `handle_session_command` to connector-core

**Difficulty: Medium | Risk: Low**

The shared function is the blocking dependency for everything else. Both session files import it, so it must move first.

### What moves

- `handle_session_command()` from `codex_session.rs` → `connector-core/src/session_loop.rs`
- The `PendingApprovalResolution`, `PersistOp` types it uses (from `session_command.rs`)

### What stays

- `SessionHandle`, `PersistCommand`, `transition` types — these need to become accessible from connector-core (either by moving them or by making the function generic over traits)

### Tasks

- [ ] Audit `handle_session_command` for every type it touches
- [ ] Decide: move dependent types to connector-core, or make the function generic over trait bounds
- [ ] Extract the function
- [ ] Update both `codex_session.rs` and `claude_session.rs` to import from connector-core
- [ ] `make rust-ci`

---

## Phase 2: Move transition state machine to connector-core

**Difficulty: Medium | Risk: Low**

The transition module maps `ConnectorEvent` → `Input` → state changes + effects. It's already provider-agnostic. Moving it to connector-core means session loops can run their state machine without importing server internals.

### What moves

- `transition.rs` → `connector-core/src/transition.rs`
- `Input`, `Effect`, `transition()` function
- The `From<ConnectorEvent> for Input` impl

### Dependencies to resolve

- `SessionHandle` methods (`extract_state()`, `apply_state()`, `broadcast()`) — transition takes a `&mut SessionHandle`
- `PersistCommand` — `Effect::Persist` wraps persist ops
- Protocol types — already in `orbitdock-protocol`

### Tasks

- [ ] Audit transition.rs for server-internal type usage
- [ ] Define trait bounds or move SessionHandle to connector-core
- [ ] Move transition.rs
- [ ] Update server + both sessions to import from new location
- [ ] `make rust-ci`

---

## Phase 3: Move CodexAuthService to connector-codex

**Difficulty: Low | Risk: Low**

`codex_auth.rs` is the most self-contained provider file. It holds a `broadcast::Sender<ServerMessage>` for pushing auth events to WebSocket clients, and imports `codex-login` for the OAuth web server.

### What moves

- `codex_auth.rs` → `connector-codex/src/auth.rs`

### Dependencies to resolve

- `broadcast::Sender<ServerMessage>` — injected at construction, easy to keep
- `codex-login`, `codex-core::auth` — already Codex deps, move naturally
- `orbitdock-protocol` types — already a connector-codex dep

### Tasks

- [ ] Move file to connector-codex
- [ ] Add `codex-login` to connector-codex Cargo.toml
- [ ] Re-export `CodexAuthService` from connector-codex
- [ ] Update `state.rs` import
- [ ] Update `websocket.rs` and `http_api.rs` imports
- [ ] Remove `codex-login` from server Cargo.toml
- [ ] `make rust-ci`

---

## Phase 4: Move session loops to per-provider crates

**Difficulty: High | Risk: Medium**

Both `ClaudeSession` and `CodexSession` run event loops that receive `ConnectorEvent`s, feed them through the transition state machine, handle effects, and process `SessionCommand`s. After phases 1-2, the shared machinery lives in connector-core.

### What moves

- `claude_session.rs` → `connector-claude/src/session.rs`
- `codex_session.rs` → `connector-codex/src/session.rs`

### Dependencies to resolve (per file)

**Both files need:**
- `SessionHandle` — passed into `start_event_loop()`, mutated throughout
- `PersistCommand` sender — for persistence effects
- `SessionRegistry` — for cleanup on exit (remove action_tx, remove_session, register thread)
- `transition()` — moved in Phase 2
- `SessionActorHandle` — created in `start_event_loop()`

**Claude-specific:**
- `session_naming::spawn_naming_task()` — AI-generated session names
- `PersistCommand::CleanupClaudeShadowSession`, `SetClaudeSdkSessionId`

**Codex-specific:**
- `PersistCommand::CleanupClaudeShadowSession` (reused for shadow cleanup)
- Thread ID management

### Strategy

Define a `SessionContext` struct (or trait) in connector-core that bundles the server-provided resources:

```rust
pub struct SessionContext {
    pub handle: SessionHandle,
    pub persist_tx: mpsc::Sender<PersistCommand>,
    pub list_tx: broadcast::Sender<ServerMessage>,
    pub on_exit: Box<dyn FnOnce() + Send>,  // cleanup callback
}
```

The server constructs this and hands it to the provider crate. The provider crate runs its event loop without knowing about SessionRegistry.

### Tasks

- [ ] Define `SessionContext` in connector-core
- [ ] Refactor `ClaudeSession::start_event_loop` to accept `SessionContext`
- [ ] Move `claude_session.rs` to connector-claude
- [ ] Refactor `CodexSession::start_event_loop` to accept `SessionContext`
- [ ] Move `codex_session.rs` to connector-codex
- [ ] Update websocket.rs, state.rs, http_api.rs imports
- [ ] Remove `ClaudeAction` / `CodexAction` from server — re-export from connector crates
- [ ] `make rust-ci`

---

## Phase 5: Move rollout_watcher to connector-codex

**Difficulty: Hard | Risk: Medium-High**

The rollout watcher is 2,646 lines of FSEvents watching, rollout file parsing, offset tracking, and session materialization. It's the most deeply coupled piece — it creates `SessionHandle`s, sends `PersistCommand`s, dispatches `SessionCommand`s to actor handles, and manages the full lifecycle of passive Codex sessions.

### What moves

- `rollout_watcher.rs` → `connector-codex/src/rollout_watcher.rs`

### The hard parts

1. **Session materialization** — the watcher creates `SessionHandle::new()` for new rollout files. After phase 4, SessionHandle construction could be behind a factory callback.

2. **Actor communication** — sends `SessionCommand` to actor handles for live sessions. Needs an abstraction layer (trait or callback) so the watcher emits "parsed rollout events" and the server dispatches commands.

3. **Persistence** — sends `RolloutSessionUpsert`, `RolloutSessionUpdate`, `EffortUpdate`, `CleanupThreadShadowSession` directly. Could be mapped through a provider-specific enum.

4. **SessionRegistry queries** — calls `is_managed_codex_thread()`, `get_session()`, `add_session()`, `remove_session()`. Needs trait or callback injection.

### Strategy: Parser + Driver split

Split rollout_watcher into two layers:

**Parser (moves to connector-codex):**
- File watching, offset tracking, JSON line parsing
- Emits typed `RolloutEvent`s (session discovered, message appended, status changed, etc.)
- No server dependencies — pure data transformation

**Driver (stays in server):**
- Subscribes to `RolloutEvent` stream
- Creates SessionHandles, sends PersistCommands, dispatches SessionCommands
- Owns the server-side lifecycle

### Tasks

- [ ] Define `RolloutEvent` enum in connector-codex
- [ ] Extract parsing logic into connector-codex (file watcher, offset tracker, JSON parser)
- [ ] Create driver module in server that consumes `RolloutEvent` stream
- [ ] Wire up: server creates watcher from connector-codex, consumes events
- [ ] Move test assertions (currently 12+ tests in rollout_watcher)
- [ ] `make rust-ci`

---

## Phase 6: Remove direct codex deps from server

**Difficulty: Low | Risk: Low**

After phases 3-5, the server should no longer import codex-core, codex-protocol, codex-login, or codex-arg0 directly. These become transitive deps through connector-codex only.

### Tasks

- [ ] Remove `codex-core`, `codex-login` from `crates/server/Cargo.toml`
- [ ] Move `codex-arg0` initialization to a connector-codex init function called from main.rs
- [ ] Verify: `cargo tree -p orbitdock-server` shows no direct codex deps
- [ ] `make rust-ci`
- [ ] `make release`

---

## What We're NOT Doing

- **No `ProviderSession` trait with dynamic dispatch** — The session loops differ fundamentally (different action enums, different creation params, different event processing). A trait adds vtable overhead and complexity with no polymorphic consumer today.
- **No Cargo feature gates** — `default = ["claude", "codex"]` would be nice but adds CI matrix complexity. Save for when there's a real need (third provider or minimal server binary).
- **No changes to the protocol crate** — It stays provider-agnostic. Provider-specific protocol types (like `CodexIntegrationMode`) already live there and that's fine.

---

## Verification (every phase)

```bash
make rust-fmt
make rust-lint       # clippy with -D warnings
make rust-test       # all workspace tests
make rust-build      # dev build
make release         # release build (catches LTO/codegen issues)
```
