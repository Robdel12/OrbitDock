# OrbitDock Server Architecture

This doc is the companion to `docs/API.md`.

`API.md` is the transport contract: routes, payloads, and wire behavior. This file is the architecture reference: code shape, ownership, and the boundaries we keep intact as the server grows.

## Goals

- Keep `crates/server` focused on server behavior, not CLI command structure.
- Keep side effects at the edges and push decisions into pure helpers where we can.
- Make transport modules thin enough that they read as delivery layers, not second application layers.
- Give each layer a clear job so the codebase stays predictable.

## Layer Ownership

### `transport/`

Owns HTTP and WebSocket delivery only.

- Parse requests
- Validate transport-level payload shape
- Call runtime/domain operations
- Translate results into API responses or pushed events

`transport` should not decide business policy. If a handler needs branching logic that is not about request parsing or response formatting, that logic probably belongs lower.

Examples:

- `transport/http/router.rs` wires routes only
- `transport/websocket/router.rs` classifies and dispatches messages only
- `transport/websocket/handlers/subscribe.rs` delegates subscribe-time reactivation, lazy connector startup, and snapshot prep to runtime helpers

### `runtime/`

Owns orchestration, live registries, actor command routing, and background coordination.

- session registries
- connector command dispatch
- runtime-only queries
- background tasks like git refresh

`runtime` is where stateful coordination lives. It is allowed to know about connectors, persistence, and long-lived tasks.

Current examples:

- `session_creation.rs`
- `session_lifecycle_policy.rs`
- `message_dispatch.rs`
- `session_subscriptions.rs`
- `restored_sessions.rs`

### `domain/`

Owns business concepts and state transitions.

- session state and transitions
- conversation/session domain models
- worktree domain behavior
- git domain operations that are not just background runtime plumbing
- mission control: config parsing, tool definitions (`tools.rs`), shared tool executor (`executor.rs`), prompt rendering, eligibility, and retry policy

`domain/mission_control/tools.rs` defines the 8 mission tools. `domain/mission_control/executor.rs` provides the shared executor used by both the MCP server (Claude) and the dynamic tool handler (Codex). The dispatch flow in `runtime/mission_dispatch.rs` writes `.mcp.json` to the worktree for Claude sessions and passes `DynamicToolSpec` entries for Codex sessions.

`domain` should be the least transport-aware part of the server.

### `infrastructure/`

Owns side-effecting services and external boundaries.

- SQLite persistence
- filesystem paths
- auth tokens
- crypto
- images
- shell execution
- usage probes

If something talks to the OS, the filesystem, SQLite, or another process, it likely belongs here.

### `support/`

Owns small shared helpers that are pure or close to pure.

- path normalization helpers
- time formatting helpers
- naming helpers

This is not a misc bucket. If a helper grows state, side effects, or domain policy, it should move out.

Current examples:

- `snapshot_compaction.rs`
- `session_modes.rs`
- `session_paths.rs`
- `session_time.rs`

### `admin/`

Owns server-admin flows exposed through the single `orbitdock` binary.

- setup/install/status/token/service commands
- command-line oriented rendering
- interactive setup orchestration

`admin` should read like a library API, not a pile of `run()` wrappers. Capability-shaped names are the default.

## API Design Rules

## Dependency Rules

These rules are the guardrails for future refactors.

- `transport` may depend on `runtime`, `domain`, `infrastructure`, and `support`.
- `runtime` may depend on `domain`, `infrastructure`, `connectors`, and `support`.
- `domain` may depend on `support`.
- `infrastructure` may depend on `support`.
- `support` should not depend on `transport`, `runtime`, `domain`, or `infrastructure`.

Just as important are the negative rules:

- `domain` must not depend on `transport`.
- `domain` should not know about connector implementations.
- `infrastructure` must not depend on `transport`.
- `support` is never a backdoor for runtime or transport behavior.

If a change wants to violate one of these, that is a design review moment, not a casual import.

## Runtime Operation Contract

The runtime layer is where orchestration belongs, but it still needs predictable shapes.

Preferred runtime module types:

- `*_policy` for pure planners and classifiers
- `*_queries` for authoritative read assembly
- `*_subscriptions` for replay/snapshot/reactivation preparation
- `*_creation` for bootstrap and persistence flows
- `*_targets` or `*_ops` for focused effectful operations

A transport handler should mostly do three things:

1. Parse the request.
2. Call a runtime operation.
3. Translate the result into a response or outbound event.

If a handler starts deciding repo roots, worktree validity, replay policy, transcript hydration, or connector reactivation inline, that logic belongs in `runtime/` or `support/`.

Runtime operations should:

- take explicit inputs
- return user-visible outcomes or shaped errors
- keep pure planning separate from side effects when practical
- avoid pulling transport types into runtime APIs unless the transport concern is the actual output

Examples:

- `session_subscriptions.rs` owns subscribe reactivation and lazy connector startup preparation
- `session_fork_policy.rs` owns fork config and history selection rules
- `session_fork_targets.rs` owns worktree fork target validation and repo-root resolution
- `message_dispatch.rs` owns send/steer/interrupt orchestration that used to sit in WebSocket handlers

## Where New Code Goes

When adding new behavior, use these rules of thumb.

### A new runtime operation

If the code coordinates actors, connectors, persistence, or background state, it belongs in `runtime/`.

Examples:

- resume or takeover preparation
- subscribe-time reactivation
- fork target resolution
- direct session startup orchestration

Good homes:

- `*_policy.rs` for pure decisions
- `*_queries.rs` for authoritative reads
- `*_subscriptions.rs` for replay/snapshot/reactivation prep
- `*_creation.rs` or `*_ops.rs` for focused effectful orchestration

### A new pure helper

If the code is mostly classification, normalization, shaping, or path/time logic, it belongs in `support/` or occasionally `domain/`.

Examples:

- model override normalization
- approval decision classification
- transcript-path derivation
- repo-root normalization

Rule:

- if it can be tested without runtime state or I/O, start by asking whether it belongs in `support/`

### A new WebSocket handler

If you are touching `transport/websocket/handlers/*`, keep the handler narrow:

1. parse the `ClientMessage`
2. call a runtime operation
3. map the result to websocket output

If the handler starts deciding policy inline, stop and move that logic lower.

### A new HTTP endpoint

HTTP endpoints follow the same rule as websocket handlers:

1. validate request shape
2. call a runtime/domain/infrastructure operation
3. map the result to JSON or an HTTP error

If a handler needs to read from SQLite directly, that should be because it is an authoritative query boundary, not because runtime orchestration was skipped.

### Prefer capability-shaped exports

Good:

- `initialize_data_dir`
- `install_claude_hooks`
- `install_background_service`
- `print_server_status`
- `issue_auth_token`

Less good:

- `run`
- `status`
- `setup`

If a function is presentation-heavy, say so with `print_*` or `run_*_wizard`.

If a function returns reusable data or performs a reusable operation, give it a capability name.

### Use planner/executor/renderer splits

For admin and runtime orchestration flows, prefer:

- `detect_*` or `prompt_*` for effectful inputs
- `plan_*` for pure decisions
- `apply_*` for side effects
- `render_*` for terminal output

That pattern gives us real unit-test seams without mocking our own code.

### Keep transport facades thin

`transport/http/mod.rs` and `transport/websocket/mod.rs` should mostly be:

- module declarations
- small shared transport helpers
- re-exports for router assembly

They should not hold large piles of endpoint business logic.

For WebSocket specifically:

- `message_groups.rs` classifies incoming messages
- `rest_only_policy.rs` maps REST-only websocket requests to their authoritative HTTP routes
- `handlers/*` adapt protocol messages onto runtime operations
- `transport.rs` owns outbound websocket delivery helpers

## HTTP Structure

The HTTP layer is organized by feature module:

- `sessions.rs`
- `session_actions.rs`
- `session_lifecycle.rs`
- `approvals.rs`
- `review_comments.rs`
- `files.rs`
- `worktrees.rs`
- `server_info.rs`
- `server_meta.rs`
- `capabilities.rs`
- `connector_actions.rs`
- `errors.rs`
- `router.rs`

`router.rs` should stay the single assembly point, but it should read in feature groups rather than as one long flat chain.

Recommended grouping:

- hook routes
- session read routes
- session write routes
- session lifecycle routes
- session action routes
- session attachment routes
- session capability routes
- approval routes
- review routes
- server routes
- filesystem routes
- worktree routes
- mission routes

## Runtime Operation Contract

When transport needs behavior that is more than trivial formatting, it should call a runtime operation or planner instead of building the flow inline.

Good runtime operations:

- prepare or load a session for resume/takeover
- plan message dispatch inputs
- prepare direct session creation
- prepare subscribe results and persisted fallback snapshots
- reactivate passive sessions when new rollout activity arrives

The pattern we want is:

1. transport parses the request
2. runtime plans or executes the operation
3. transport renders the response or pushes events

That keeps policy and orchestration centralized, and it makes outcome-focused tests much easier to write.

## WebSocket Structure

The websocket layer has a deliberately narrow shape:

- `router.rs` is the single dispatch entrypoint
- `message_groups.rs` owns top-level message classification
- `rest_only_policy.rs` owns the mapping from websocket requests to REST routes
- `handlers/subscribe.rs` is focused on routing subscribe requests, not rebuilding subscription state by hand
- `transport.rs` owns replay/snapshot delivery behavior

## Testing Rules

We want confidence, not coverage theater.

- Test outcomes, not whether helper A called helper B.
- Prefer pure unit tests for planners and classifiers.
- Use integration tests for real boundaries like temp files, SQLite, and request handlers.
- Do not mock our own admin/runtime code.
- Mock only external services, time, or randomness when we truly need to.

Examples:

- `pair.rs`: unit test URL normalization and token messaging
- `setup.rs`: unit test setup planning decisions
- `remote_setup.rs`: unit test exposure-mode planning and summary rules
- `doctor.rs`: unit test report classification and summary counts
- HTTP handlers: integration test request/response behavior with real state and temp files
- runtime planners and policies: unit test pure branches directly
- WebSocket and HTTP handlers: keep tests focused on routing, payloads, and delivery outcomes

### Transport Test Rule

When a transport-layer test only proves a pure helper, move that test beside the helper.

Keep transport tests for:

- request routing
- authoritative response payloads
- snapshot and replay delivery behavior
- connector command dispatch
- cross-layer integration outcomes
