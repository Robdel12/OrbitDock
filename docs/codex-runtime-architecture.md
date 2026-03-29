# Codex Runtime Architecture

This doc scopes a new Codex runtime architecture for OrbitDock.

The goal is simple:

- keep OrbitDock's server-authoritative model
- support app-server-first Codex features cleanly
- preserve the flexibility of direct crate integration
- stop baking one specific Codex runtime choice into every server seam

This is the design follow-up to [codex-rust-v0.117.0-scope.md](/Users/robertdeluca/Developer/OrbitDock/docs/codex-rust-v0.117.0-scope.md).

## Why Change This

OrbitDock's current direct Codex integration was a sensible choice.

It gave us:

- tight control over event normalization
- no subprocess in the main live-session path
- a natural fit for OrbitDock's server-owned transport contract

But upstream is clearly building product velocity around app-server. That is where major new client-facing workflows are landing first.

Today we already have a split world:

- live Codex sessions run through embedded `codex-core`
- some utility reads already shell out to `codex app-server`
- plugin response types come from `codex-app-server-protocol`
- app-server-only features like `thread/shellCommand` and `fs/watch` do not fit the current runtime shape

That drift is the real problem.

## Invariant To Protect

OrbitDock server remains the source of truth.

The native app should still talk only to OrbitDock's HTTP and WebSocket APIs. It should not become a direct Codex app-server client.

That means:

- HTTP still owns bootstrap, heavy reads, and mutations
- WebSocket still owns replay, deltas, and refetch hints
- SQLite and the session actor remain the durable business authority
- Codex runtime changes stay behind the server boundary

This is non-negotiable. It keeps us aligned with [data-flow.md](/Users/robertdeluca/Developer/OrbitDock/docs/data-flow.md) instead of replacing one clean architecture problem with three new ones.

## Current Shape

The current Codex runtime seam is too low-level.

We already have good normalization at the event layer:

- connectors emit `ConnectorEvent`
- the session actor consumes those through `SessionCommand::ProcessEvent`
- durable state changes still flow through `SessionHandle`, persistence commands, and server-authored deltas

That part is strong.

The part that leaks is control and lifecycle.

Codex-specific action channels, start paths, resume paths, takeover paths, approval dispatch, and HTTP connector query helpers all know about the concrete `CodexAction` type today.

You can see that in:

- `orbitdock-server/crates/connector-codex/src/session.rs`
- `orbitdock-server/crates/server/src/runtime/session_direct_start.rs`
- `orbitdock-server/crates/server/src/runtime/session_resume.rs`
- `orbitdock-server/crates/server/src/runtime/session_takeover.rs`
- `orbitdock-server/crates/server/src/runtime/message_dispatch.rs`
- `orbitdock-server/crates/server/src/runtime/approval_dispatch.rs`
- `orbitdock-server/crates/server/src/transport/http/connector_actions.rs`
- `orbitdock-server/crates/server/src/runtime/session_registry/connector_registry.rs`

That makes the current runtime choice contagious.

## Target Architecture

Move the seam up one level.

OrbitDock should own a provider-neutral Codex runtime contract, and then plug different implementations into it.

The two initial implementations are:

1. `EmbeddedCoreCodexRuntime`
2. `AppServerCodexRuntime`

Passive rollout watching stays separate. It is not a direct-session runtime.

## What Stays The Same

These layers should not fundamentally change:

- the native app contract
- session actor semantics
- `ConnectorEvent` as the normalized event language
- `SessionCommand` as the session mutation/query language
- persistence ownership in the Rust server

That is the point of this design. We are changing the Codex runtime substrate, not rewriting OrbitDock's whole session system.

## The New Codex Runtime Boundary

The server should stop depending on a concrete `CodexAction` channel and instead depend on a generic Codex runtime handle.

At a high level, the new model looks like this:

```text
OrbitDock HTTP / WS
        |
        v
 Session actor + domain transitions
        |
        v
   CodexRuntimeHandle  <----- provider-neutral control surface
        |
        +---- EmbeddedCoreCodexRuntime
        |
        +---- AppServerCodexRuntime
```

The runtime handle should expose:

- a stream of normalized `ConnectorEvent`s
- a typed control channel for session actions
- runtime identity and capability metadata

## Proposed Types

The exact Rust names can change, but the shape should be close to this.

### Runtime kind

```rust
enum CodexRuntimeKind {
    EmbeddedCore,
    AppServer,
}
```

This should be distinct from `CodexIntegrationMode`.

`CodexIntegrationMode` is still useful for user-facing session semantics like:

- `direct`
- `passive`

But it is the wrong type for the backend implementation choice.

We should add a new persisted concept for runtime backend selection, something like:

```rust
enum CodexRuntimeBackend {
    EmbeddedCore,
    AppServer,
}
```

## Runtime actions

Replace the concrete `CodexAction` surface with a provider-neutral action enum.

Something like:

```rust
enum CodexRuntimeAction {
    SendMessage { ... },
    SteerTurn { ... },
    Interrupt,
    ApproveExec { ... },
    ApprovePatch { ... },
    AnswerQuestion { ... },
    RequestPermissionsResponse { ... },
    UpdateConfig { ... },
    SetThreadName { ... },
    ListSkills { ... },
    ListPlugins { ... },
    ReadPlugin { ... },
    InstallPlugin { ... },
    UninstallPlugin { ... },
    ListMcpTools,
    RefreshMcpServers,
    Compact,
    Undo,
    ThreadRollback { ... },
    ForkSession { ... },
    EndSession,
}
```

This should describe OrbitDock intent, not upstream transport mechanics.

That distinction matters.

For example:

- `AppServerCodexRuntime` may implement `SendMessage` through `turn/start`
- `EmbeddedCoreCodexRuntime` may implement it through the current direct connector

The session runtime should not care.

## Runtime handle

Each runtime implementation should return a common handle:

```rust
struct CodexRuntimeHandle {
    kind: CodexRuntimeKind,
    capabilities: CodexRuntimeCapabilities,
    action_tx: mpsc::Sender<CodexRuntimeAction>,
    event_rx: mpsc::Receiver<ConnectorEvent>,
    binding: CodexRuntimeBinding,
}
```

Where:

```rust
struct CodexRuntimeBinding {
    external_thread_id: Option<String>,
    session_source: Option<String>,
}
```

And:

```rust
struct CodexRuntimeCapabilities {
    supports_plugins: bool,
    supports_plugin_read: bool,
    supports_thread_shell_command: bool,
    supports_fs_watch: bool,
    supports_remote_transport: bool,
    supports_multi_agent_v2: bool,
}
```

This gives us a future-proof way to gate behavior by capability rather than by hard-coded version checks.

## Why Capabilities Matter

We should expect Codex to keep evolving quickly.

Future-proof here does not mean "predict every future API."
It means:

- do not spread version-specific conditionals across the app
- do not assume embedded-core and app-server always reach parity
- do not make the native app infer what a runtime can do

The runtime adapter should decide what is supported and expose that as typed capability metadata. The server can then surface only the stable product truth the client needs.

## Implementation Model

Each Codex runtime should own its own task and translate upstream behavior into OrbitDock concepts.

### Embedded core runtime

This wraps the current direct connector.

It should:

- keep using `codex-core`
- keep translating upstream events into `ConnectorEvent`
- adapt current direct commands into `CodexRuntimeAction`

This lets us keep all the flexibility we already earned from direct crate integration.

### App-server runtime

This wraps the app-server product surface.

It should:

- use the official app-server client path, not a handwritten JSON-RPC layer
- translate app-server notifications and request/response flows into `ConnectorEvent`
- translate `CodexRuntimeAction` into app-server requests like `thread/*`, `turn/*`, `plugin/*`, and later `fs/*`

This gives us access to the upstream-native runtime without leaking that transport into the rest of OrbitDock.

## Recommended Process Model For App-Server

Do not spawn one app-server process per session.

That fights the upstream model.

App-server is thread-oriented and already designed to multiplex many conversations.

The better starting point is:

- one supervised local app-server process per OrbitDock server instance
- one shared app-server client connection manager
- many OrbitDock sessions mapped to many app-server threads

Benefits:

- closer to upstream's intended model
- simpler auth and config handling
- easier support for future remote websocket mode
- less process overhead

We can keep the transport abstraction flexible enough to swap the local supervised app-server for a remote websocket app-server later.

## Recommended App-Server Client Strategy

Prefer the official app-server client crate or equivalent official transport helper over custom JSON-RPC glue.

OrbitDock already has a few narrow manual app-server calls today. That was fine for utility reads.

For a real long-lived runtime, a custom client would become maintenance debt almost immediately.

Use the official client path where possible.

## Normalization Strategy

The event normalization boundary should stay at `ConnectorEvent`.

That means:

- app-server item notifications are not sent directly to the native app
- app-server request payloads are not treated as durable business truth
- the runtime adapter turns them into OrbitDock events, rows, approvals, subagent updates, and capability broadcasts

When app-server introduces a genuinely new concept, the fix should be:

1. add a typed OrbitDock event or typed state field
2. update persistence and broadcast layers if it is durable
3. let the client render that typed concept

Not:

- "just pipe the JSON through"

## Session Lifecycle Changes

The direct Codex start, resume, and takeover flows should stop constructing concrete `CodexSession` objects directly.

Instead, they should ask a runtime factory for a `CodexRuntimeHandle`.

Something like:

```rust
trait CodexRuntimeFactory {
    async fn start_direct(... ) -> Result<CodexRuntimeHandle, CodexRuntimeError>;
    async fn resume_direct(... ) -> Result<CodexRuntimeHandle, CodexRuntimeError>;
    async fn takeover_passive(... ) -> Result<CodexRuntimeHandle, CodexRuntimeError>;
}
```

That moves runtime choice out of:

- `session_direct_start.rs`
- `session_resume.rs`
- `session_takeover.rs`

And into one deliberate place.

## Registry Changes

The current connector registry is also too concrete.

Today it stores:

- `mpsc::Sender<CodexAction>`
- `mpsc::Sender<ClaudeAction>`
- provider-specific external thread maps

That should become more generic for Codex.

Recommended direction:

- replace `codex_actions` with `codex_runtime_actions`
- store runtime kind and thread binding alongside the sender
- keep provider-specific identities where they matter, but stop making the control channel itself runtime-specific

This makes future app-server-backed Codex sessions look the same to the rest of the server.

## Approval And Message Dispatch Changes

`message_dispatch.rs`, `approval_dispatch.rs`, and HTTP connector query helpers should dispatch through the generic Codex runtime action surface, not through `CodexAction`.

That is one of the biggest cleanup wins in this design.

Right now those layers know too much about the concrete runtime choice.

After this change, they should only know:

- is this a Codex session
- what OrbitDock is asking the runtime to do
- whether the runtime reported success, failure, or unavailability

## Persistence Changes

We should persist runtime backend selection for direct Codex sessions.

Why:

- resume behavior depends on it
- takeover behavior depends on it
- debugging depends on it
- migration between backends should be explicit

Suggested new persisted field:

- `codex_runtime_backend`

Suggested values:

- `embedded_core`
- `app_server`

Do not overload `codex_integration_mode` for this.

That field means something different today.

## Capability Surface

The server should expose Codex runtime capability truth as part of session state or a closely related surface.

That might include:

- plugin support
- plugin read/install auth follow-up support
- app-server shell command support
- filesystem watch support
- remote runtime support

The client should not guess from runtime backend names alone. Backend and capability are related, but not identical.

This is especially important for future releases where embedded-core may catch up on some features or app-server may gate features behind capability flags.

## What We Should Not Do

Do not:

- make the native app a direct app-server client
- expose raw app-server JSON-RPC over OrbitDock WebSocket
- add version checks all over the codebase
- replace `ConnectorEvent` with untyped protocol payloads
- keep two entirely separate Codex product models in the client

That would make upgrades harder, not easier.

## Migration Plan

## Phase 0: Name the concepts

- add `CodexRuntimeBackend`
- add `CodexRuntimeKind`
- add `CodexRuntimeCapabilities`
- add a provider-neutral `CodexRuntimeAction` surface

No behavior change yet.

## Phase 1: Put the current embedded runtime behind the new interface

- adapt the current direct connector to the new runtime contract
- change registry storage from `CodexAction` to `CodexRuntimeAction`
- update message dispatch, approvals, and HTTP query helpers to use the new contract

This is the make-it-boring phase.

The goal is to prove the abstraction against the runtime we already trust.

## Phase 2: Add app-server supervisor and runtime adapter

- add a supervised local app-server process manager
- add a shared app-server client manager
- implement `AppServerCodexRuntime`
- translate app-server thread/item/approval/plugin flows into `ConnectorEvent`

Still do not change the native client contract.

## Phase 3: Add runtime selection

- choose backend for new direct Codex sessions
- persist backend choice
- route resume/takeover through the correct runtime factory
- expose runtime capabilities to OrbitDock session state

At first, make this opt-in.

## Phase 4: Reach parity on the workflows that matter

Use app-server runtime to unlock:

- first-class plugins
- app-server-native subagent behavior
- `thread/shellCommand`, if we choose to support it
- filesystem watch, if we choose to surface it

Do not flip defaults until session creation, resume, approval handling, and core transcript rendering are trustworthy.

## Phase 5: Make app-server the default direct runtime

Once parity is good enough:

- new direct Codex sessions default to app-server backend
- embedded-core remains supported as fallback and escape hatch

That last part matters.

Keeping embedded-core as a supported backend is the hedge that preserves flexibility for future upstream shifts.

## Why Keep Embedded Core At All

Because it still has real strategic value.

Direct crate integration gives us:

- freedom to experiment
- lower-level access when upstream app-server abstractions lag
- a path for niche or performance-sensitive features later
- resilience if app-server semantics change in ways that do not fit OrbitDock

So the right move is not "replace direct integration."

It is:

- stop making direct integration the only shape OrbitDock understands

## Risks

### Risk: Adapter leaks

If `CodexRuntimeAction` just becomes a thin rename of app-server methods, the abstraction failed.

The action surface must describe OrbitDock intent.

### Risk: Event mismatch

App-server may expose richer or differently grouped item streams than direct core.

We need to normalize carefully and only promote new durable concepts when they matter.

### Risk: Resume complexity

App-server thread identity, embedded-core thread identity, and passive rollout identity all need clean ownership and persistence rules.

Do not patch this with string heuristics.

### Risk: Dual-runtime test matrix

Once we support both backends, parity drift becomes possible.

We should expect a targeted test matrix around:

- send
- steer
- interrupt
- approvals
- plugin flows
- fork
- resume
- subagent updates

## Recommended First Build Slice

If we decide to move on this architecture, the first implementation slice should be:

1. add the new Codex runtime types and registry seam
2. adapt embedded-core to that seam
3. keep behavior unchanged
4. only then add app-server runtime

That keeps the migration honest.

It also lets the compiler tell us every place where the current concrete Codex runtime leaks into the server.

That is exactly the kind of pressure we want.

## Bottom Line

OrbitDock should become runtime-agnostic for direct Codex sessions.

The server-owned truth, actor model, and client transport contract are worth keeping.

The piece that should change is the Codex runtime boundary.

That gives us the best of both worlds:

- app-server alignment for where Codex is going
- direct crate flexibility for where Codex might go next
