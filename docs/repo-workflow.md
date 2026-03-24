# Repo Workflow

Use this doc for the day-to-day mechanics of working in OrbitDock: where code goes, which commands to run, and what level of testing is expected.

## Project Shape

OrbitDock has two main parts:

- `OrbitDockNative/OrbitDock/` — the macOS and iOS SwiftUI app
- `orbitdock-server/` — the Rust server, CLI, persistence, and provider integrations

Shared Swift models live in `OrbitDockNative/OrbitDockCore/`. SQL migrations live in `orbitdock-server/migrations/`.

## Where Code Goes

### Swift client

- `Views/` renders UI and keeps local presentation state
- `Services/Server/` owns endpoint runtimes, transport, request orchestration, and event handling
- `Models/` holds app-facing types
- `Platform/` holds OS-specific glue

### Rust server

- `crates/cli/` — CLI parsing and command dispatch
- `crates/server/src/app/` — startup and top-level wiring
- `crates/server/src/transport/http/` — REST transport
- `crates/server/src/transport/websocket/` — WebSocket transport
- `crates/server/src/runtime/` — orchestration, registries, actors
- `crates/server/src/domain/` — business logic and pure state transitions
- `crates/server/src/infrastructure/` — SQLite, filesystem, auth, crypto, metrics
- `crates/server/src/connectors/` — provider-specific glue
- `crates/server/src/support/` — small shared helpers
- `crates/server/src/admin/` — server-admin capabilities exposed through the binary

## Commands

From the repo root:

```bash
make build
make build-ios
make build-all
make test-unit
make test-ui
make test-all
make fmt
make lint
make rust-build
make rust-check
make rust-check-workspace
make rust-test
make rust-ci
make rust-run
make rust-run-debug
make cli ARGS='session list'
```

## Rust Workflow Policy

Use `make rust-*` targets for normal Rust development.
They route artifacts into the shared repo cache, auto-enable `sccache` when available, and avoid duplicate target directories from ad-hoc cargo invocations.
The root [Makefile](/Users/robertdeluca/Developer/OrbitDock/Makefile) now keeps shared config and help text, while target families live under `make/*.mk`.

Do not run plain `cargo` commands unless you are adding or fixing a Make target. The Make targets carry the repo's intended cache and build settings and avoid duplicate build directories.

If a Rust command is missing, add the right Make target first, then run it through `make`.

## Testing Expectations

Use the smallest meaningful test set that gives real confidence.

### Swift

- tests live in `OrbitDockNative/OrbitDockTests/`
- use `make test-unit` for normal verification
- use `make test-ui` only when UI automation is relevant

### Rust

- use `make rust-check` for the fast shipped-package compile check
- use `make rust-check-workspace` when you're changing shared crates or workspace wiring
- use `make rust-test` for behavior changes
- use `make rust-ci` when you need the full Rust quality pass

### Web frontend

For orbitdock-web testing principles, read [web-testing-strategy.md](web-testing-strategy.md). It covers the test pyramid, where each kind of test belongs, and what we explicitly avoid.

### Integration work

For Claude or Codex integration changes, verify the behavior in a real session when you can. Hook-forwarding and rollout-watcher code is hard to trust from unit tests alone.

## Migrations

Create migrations as `orbitdock-server/migrations/VNNN__description.sql`.

When a schema change affects behavior:

1. update the Rust persistence layer
2. update startup hydration or restore logic if needed
3. update protocol types if the field needs to reach clients
4. run the relevant `make rust-*` checks

For deeper persistence rules, read [database-and-persistence.md](database-and-persistence.md).

## Mission Control

Mission Control is configured through repo-local `MISSION.md`.

Keep orchestration logic server-driven. The client should render mission state, not own it.

Use [sample-mission.md](sample-mission.md) for the example config.
