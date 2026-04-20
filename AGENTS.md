# Repository Guidelines

`AGENTS.md` is the front door, not the handbook.

Start here, then jump to the right doc.

## Read This First

If you're making code changes, these are the docs that matter most:

- [docs/GETTING_STARTED.md](docs/GETTING_STARTED.md) — project setup, build commands, testing, and day-to-day workflow
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — client patterns, server state architecture, and guardrails
- [docs/web-testing-strategy.md](docs/web-testing-strategy.md) — orbitdock-web testing principles: what to test where, mocking rules, hard lines
- [docs/OPERATIONS.md](docs/OPERATIONS.md) — server deployment, persistence, debugging, and troubleshooting

## Short Version

OrbitDock has two main parts:

- `OrbitDockNative/OrbitDock/` — SwiftUI app for macOS and iOS
- `orbitdock-server/` — Rust server, CLI, persistence, and provider integrations

The repo rules are simple:

- keep durable business truth on the server
- apply authoritative `POST`/`PATCH`/`PUT` responses to local state immediately, then let subscriptions reconcile
- use `make rust-*` targets instead of plain `cargo`
- keep shared Make config in the root `Makefile` and target families in `make/*.mk`
- keep SQLite ownership in the Rust server
- prefer focused docs in `docs/` over growing this file again

## Native App Workflow

For Swift app work, prefer the newer plugin skills and MCP tools over ad hoc shell workflows.

- use the `Build iOS Apps` plugin for iOS build, simulator, UI inspection, screenshots, logs, and debugger flows
- use the `Build macOS Apps` plugin for macOS build, run, test, debug, telemetry, and packaging flows
- when the task clearly matches one of the native skills, load it first instead of reaching straight for raw `xcodebuild`
- prefer `build-ios-apps:ios-debugger-agent` for simulator runs and interactive iOS debugging
- prefer `build-macos-apps:build-run-debug` for local macOS build and launch work, and `build-macos-apps:test-triage` when macOS tests fail
- prefer the `mcp__xcodebuildmcp__*` tool family for simulator control, screenshots, UI snapshots, log capture, and Xcode-backed build/test actions
- use shell `xcodebuild` or `swift build` as a fallback when the MCP/plugin path does not cover the task cleanly

## Native Data Flow Rules

Selected-session boot order is defined in [docs/data-flow.md](docs/data-flow.md). The control deck is composer UI only; it must not own session bootstrap, WebSocket subscription, or business-state truth.

## State Mutation Rules

**Functional. Pure. Immutable. Single mutation path.**

1. All database writes go through `PersistCommand` — no direct SQL outside persistence layer
2. Immutable fields (`claude_sdk_session_id`, `codex_thread_id`) cannot be overwritten once set
3. In-memory state is frozen after initial write
4. SQLite triggers enforce immutability as hard stop — code bugs cannot corrupt data

## Hooks Are Passive

Hooks are passive reporters — they observe and report, nothing more.

1. Hooks NEVER mutate direct session state
2. Hooks NEVER write to `claude_sdk_session_id` or `codex_thread_id` of a direct session
3. Hook sessions are ephemeral sugar — they report events, they don't own state
4. If a hook is touching direct session state, the architecture is backwards

## Documentation Map

- [docs/GETTING_STARTED.md](docs/GETTING_STARTED.md) — setup, build commands, testing, key patterns
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — client patterns, server state architecture, and guardrails
- [docs/web-testing-strategy.md](docs/web-testing-strategy.md) — orbitdock-web testing principles and hard lines
- [docs/OPERATIONS.md](docs/OPERATIONS.md) — deployment, database, debugging, and troubleshooting
- [docs/data-flow.md](docs/data-flow.md) — REST/WS data contract and surface model
- [docs/design-system.md](docs/design-system.md) — unified design system (Cosmic Harbor) and typography
- [docs/tool-rendering-spec.md](docs/tool-rendering-spec.md) — tool display contracts and rendering specs
- [docs/FEATURES.md](docs/FEATURES.md) — product capabilities and user-facing features

If a section starts turning into a handbook, move it into `docs/` and link it here.
