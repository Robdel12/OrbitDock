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
