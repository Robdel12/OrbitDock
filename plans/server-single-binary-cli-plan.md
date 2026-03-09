# Server Single-Binary CLI Plan

This document is **historical**.

The refactor described here is complete enough that this file should no longer be treated as the source of truth for current architecture. If you want the live picture, read [`orbitdock-server/docs/server-architecture.md`](../orbitdock-server/docs/server-architecture.md).

## What Landed

The single-binary model stayed intact.

- `orbitdock` is still the one binary users install and run
- `crates/cli` owns the binary entrypoint and command dispatch
- `crates/server` is library-first and owns the server runtime plus reusable admin capabilities
- Server code is organized by responsibility instead of a flat crate root

## Current Shape

Today the server side is split like this:

- `crates/cli/` for argument parsing, command routing, client-side command dispatch, and output
- `crates/server/src/app/` for startup and top-level runtime wiring
- `crates/server/src/admin/` for reusable install/setup/status/token/service/tunnel/pair operations
- `crates/server/src/runtime/` for orchestration, registries, actor coordination, and background flows
- `crates/server/src/transport/` for HTTP and WebSocket delivery
- `crates/server/src/domain/` for business rules and state transitions
- `crates/server/src/infrastructure/` for SQLite, paths, auth, crypto, logging, shell, and other side effects
- `crates/server/src/connectors/` for Claude/Codex integration
- `crates/server/src/support/` for small shared pure helpers

## Practical Rule

If you're making a server change and you're not sure where it belongs, use `server-architecture.md` first. This file is just the breadcrumb that explains why the old plan references no longer match the repo.
