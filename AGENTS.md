# Repository Guidelines

`AGENTS.md` is the front door, not the handbook.

Start here, then jump to the right doc.

## Read This First

If you're making code changes, these are the docs that matter most:

- [docs/repo-workflow.md](docs/repo-workflow.md) — project shape, commands, testing, and day-to-day workflow
- [docs/web-testing-strategy.md](docs/web-testing-strategy.md) — orbitdock-web testing principles: what to test where, mocking rules, hard lines
- [docs/engineering-guardrails.md](docs/engineering-guardrails.md) — architecture and persistence rules that are easy to violate
- [docs/local-development.md](docs/local-development.md) — local setup flow, file locations, and CLI basics
- [docs/debugging.md](docs/debugging.md) — logs, hook checks, and database inspection
- [docs/database-and-persistence.md](docs/database-and-persistence.md) — migration and persistence rules

## Short Version

OrbitDock has two main parts:

- `OrbitDockNative/OrbitDock/` — SwiftUI app for macOS and iOS
- `orbitdock-server/` — Rust server, CLI, persistence, and provider integrations

The repo rules are simple:

- keep durable business truth on the server
- use `make rust-*` targets instead of plain `cargo`
- keep shared Make config in the root `Makefile` and target families in `make/*.mk`
- keep SQLite ownership in the Rust server
- prefer focused docs in `docs/` over growing this file again

## Documentation Map

- [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md) — contributor setup and repo tour
- [docs/repo-workflow.md](docs/repo-workflow.md) — commands, file placement, and testing expectations
- [docs/web-testing-strategy.md](docs/web-testing-strategy.md) — orbitdock-web testing principles and hard lines
- [docs/engineering-guardrails.md](docs/engineering-guardrails.md) — server-authoritative rules, protocol guidance, UI constraints
- [docs/CLIENT_DESIGN_PRINCIPLES.md](docs/CLIENT_DESIGN_PRINCIPLES.md) — short Swift client guardrails
- [docs/SWIFT_CLIENT_ARCHITECTURE.md](docs/SWIFT_CLIENT_ARCHITECTURE.md) — durable client architecture rules
- [docs/client-networking.md](docs/client-networking.md) — networking lifecycle and readiness rules
- [docs/data-flow.md](docs/data-flow.md) — REST/WS data contract
- [docs/UI_CROSS_PLATFORM_GUIDELINES.md](docs/UI_CROSS_PLATFORM_GUIDELINES.md) — shared cross-platform UI rules
- [docs/design-system.md](docs/design-system.md) — unified design system (Cosmic Harbor)
- [docs/typography.md](docs/typography.md) — typography system
- [docs/local-development.md](docs/local-development.md) — setup flow, file locations, CLI basics
- [docs/debugging.md](docs/debugging.md) — logs, filters, and inspection commands
- [docs/database-and-persistence.md](docs/database-and-persistence.md) — migrations, schema rules, persistence model
- [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) — deployment and install flows
- [docs/FEATURES.md](docs/FEATURES.md) — product capability overview
- [docs/NORTH_STAR.md](docs/NORTH_STAR.md) — product direction
- [docs/sample-mission.md](docs/sample-mission.md) — example `MISSION.md`

If a section starts turning into a handbook, move it into `docs/` and link it here.
