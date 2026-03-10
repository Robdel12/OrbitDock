# OrbitDock Swift Client

This is the SwiftUI client for OrbitDock on macOS and iOS.

It is an endpoint-aware UI over a server-authoritative system:

- the Rust server owns durable session state and business rules
- the client renders that state, sends user intent, and manages local presentation
- REST handles client-initiated reads and mutations
- WebSocket handles server-pushed events and real-time session interaction

## Where Things Go

- `OrbitDock/OrbitDock/Views/` contains feature UI
- `OrbitDock/OrbitDock/Services/Server/` contains endpoint runtimes, transport, and session orchestration
- `OrbitDock/OrbitDock/Models/` contains app-facing domain and view data
- `OrbitDock/OrbitDock/Navigation/` contains routing and app shell navigation state
- `OrbitDock/OrbitDock/Platform/` contains OS-specific glue

If a new feature needs durable session truth, change the server contract first. The client should not infer server-owned business state from history.

## Architecture Docs

- [docs/SWIFT_CLIENT_ARCHITECTURE.md](../docs/SWIFT_CLIENT_ARCHITECTURE.md) is the source of truth for client layer boundaries, state ownership, and coordination rules
- [orbitdock-server/docs/API.md](../orbitdock-server/docs/API.md) is the source of truth for the HTTP and WebSocket contract
- [docs/CONTRIBUTING.md](../docs/CONTRIBUTING.md) covers local setup and development workflow

## Testing

Client tests should follow the same bar we used for the server:

- test user outcomes, not internal call order
- prefer pure helpers and deterministic state transitions
- use integration-style tests at real transport boundaries
- avoid UI tests unless a workflow truly requires them
- avoid arbitrary sleeps and polling

That means most client coverage should live in `OrbitDock/OrbitDockTests/`, with unit tests for pure policy helpers and integration-style tests for transport, stores, and runtime coordination.
