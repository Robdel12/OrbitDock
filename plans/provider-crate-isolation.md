# Provider Crate Isolation

> Decouple Claude and Codex provider logic from the server crate so that working on one provider never recompiles the other, and the server becomes a provider-agnostic orchestrator.

---

## Why We Are Doing This

The server binary can't compile without Codex even if you only want Claude. Provider-specific session management, auth, and file watching live in `crates/server/` with deep tentacles into server internals (SessionRegistry, PersistCommand, transition state machine). This means:

- Every `make rust-build` pulls in codex-core's heavy git dep + patched tungstenite forks
- Provider logic is tangled with orchestration logic — hard to reason about boundaries
- Adding a third provider means touching server internals instead of just registering a new crate

### Current State (complete)

```
server/
├── claude_session.rs              ← Thin event loop (~240 lines), delegates to shared dispatch
├── codex_session.rs               ← Thin event loop (~190 lines), delegates to shared dispatch
├── session_command_handler.rs     ← Shared event dispatch, command handler, watchdog helpers
├── rollout_watcher.rs             ← FSEvents driver (~1,080 lines), dispatches parsed RolloutEvents
├── transition.rs                  ← Re-exports connector-core transition + PersistOp mapping
├── session.rs                     ← SessionHandle (shared state)
├── session_actor.rs               ← Actor loop (provider-agnostic)
├── session_command.rs             ← SessionCommand enum
├── persistence.rs                 ← PersistCommand channel
└── state.rs                       ← SessionRegistry (global app state)

connector-claude/
├── src/lib.rs                     ← Protocol parsing, image transforms
└── src/session.rs                 ← ClaudeSession, ClaudeAction, CLI subprocess

connector-codex/
├── src/lib.rs                     ← Re-exports, codex-arg0 init
├── src/session.rs                 ← CodexSession, CodexAction, connector lifecycle
├── src/auth.rs                    ← CodexAuthService (OAuth via codex-login)
└── src/rollout_parser.rs          ← Typed JSONL parser (codex-protocol types)

connector-core/
├── src/lib.rs                     ← Re-exports
├── src/event.rs                   ← ConnectorEvent
├── src/error.rs                   ← ConnectorError
└── src/transition.rs              ← Pure state machine (Input, Effect, WorkPhase)
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

## Phase 1: Extract `handle_session_command` ✅

Extracted to `server/src/session_command_handler.rs` (kept in server, not connector-core, because it depends deeply on `SessionHandle`, `PersistCommand`, and `transition`). Both provider event loops import from the shared module.

---

## Phase 2: Move transition state machine to connector-core ✅

Moved to `connector-core/src/transition.rs`. The server keeps a thin shim (`server/src/transition.rs`) that re-exports everything and adds `persist_op_to_command()` — a free function mapping `PersistOp` → `PersistCommand` (orphan rule prevents adding methods to foreign types).

---

## Phase 3: Move CodexAuthService to connector-codex ✅

Moved to `connector-codex/src/auth.rs`. Zero server dependencies — purely codex-core, codex-login, and protocol types. `codex-login` removed from server Cargo.toml.

---

## Phase 4: Move session structs + action enums to per-provider crates ✅

Moved `ClaudeAction`, `ClaudeSession` (struct + `new()` + `handle_action()`) to `connector-claude/src/session.rs`, and `CodexAction`, `CodexSession` (struct + `new()` + `resume()` + `thread_id()` + `handle_action()`) to `connector-codex/src/session.rs`.

Event loops (`start_event_loop`, `handle_event_direct`) stay in the server as free functions since they depend deeply on `SessionHandle`, `PersistCommand`, `SessionActorHandle`, and `SessionRegistry`. Server modules re-export types for API compatibility.

---

## Phase 5: Split rollout_watcher — Parser/Driver ✅

Parser/driver split. Pure parsing logic moved to `connector-codex/src/rollout_parser.rs` (~750 lines) using typed `codex-protocol` deserialization (`RolloutLine`, `RolloutItem`, `EventMsg`, `ResponseItem`). Replaces all raw `serde_json::Value` hand-matching with serde-derived types.

Server keeps the driver in `rollout_watcher.rs` (~1,080 lines) — dispatches `RolloutEvent`s to `SessionHandle`, `PersistCommand`, and `SessionRegistry`. Net reduction of ~1,500 lines from the server crate.

---

## Phase 6: Remove direct codex deps from server ✅

Removed `codex-core` (unused) and `codex-arg0` from server Cargo.toml. `arg0_dispatch()` is re-exported through `connector-codex`. `cargo tree -p orbitdock-server --depth 1` shows zero direct codex crates — only `orbitdock-connector-codex`.

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
