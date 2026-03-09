# OrbitDock Server Architecture

This doc is the companion to `docs/API.md`.

`API.md` is about routes and payloads. This file is about code shape, ownership, and how we want the server to keep evolving without sliding back into a giant crate root.

## Goals

- Keep `crates/server` focused on server behavior, not CLI command structure.
- Keep side effects at the edges and push decisions into pure helpers where we can.
- Make transport modules thin enough that they read as delivery layers, not second application layers.
- Make refactors safe by giving each layer a clear job.

## Layer Ownership

### `transport/`

Owns HTTP and WebSocket delivery only.

- Parse requests
- Validate transport-level payload shape
- Call runtime/domain operations
- Translate results into API responses or pushed events

`transport` should not decide business policy. If a handler needs branching logic that is not about request parsing or response formatting, that logic probably belongs lower.

### `runtime/`

Owns orchestration, live registries, actor command routing, and background coordination.

- session registries
- connector command dispatch
- runtime-only queries
- background tasks like git refresh

`runtime` is where stateful coordination lives. It is allowed to know about connectors, persistence, and long-lived tasks.

### `domain/`

Owns business concepts and state transitions.

- session state and transitions
- conversation/session domain models
- worktree domain behavior
- git domain operations that are not just background runtime plumbing

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

### `admin/`

Owns server-admin flows exposed through the single `orbitdock` binary.

- setup/install/status/token/service commands
- command-line oriented rendering
- interactive setup orchestration

`admin` should read like a library API, not a pile of `run()` wrappers. Capability-shaped names are the default.

## API Design Rules

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

## Concurrency-Friendly Work Splits

This architecture is designed so multiple workers can make progress safely.

Good parallel slices:

- `admin/*` API shaping and planner extraction
- `transport/http/*` facade thinning and router grouping
- `runtime/*` command/query cleanup
- docs and tests for the newly extracted pure helpers

Avoid overlapping:

- `session_lifecycle.rs` and deep runtime session command changes in the same pass
- facade thinning and broad import rewrites in the same diff unless the write set is very small

## Current Direction

The current cleanup has already done the big structural work:

- `crates/cli` owns the single binary
- `crates/server` is library-first
- root-level `cmd_*` is gone from the server crate
- server modules are grouped by responsibility

The next phase is about quality of seams:

- make admin APIs read like a library
- keep transport layers thin
- move decision-heavy flows behind pure planners
- keep documentation and tests close behind the code so the new structure sticks
