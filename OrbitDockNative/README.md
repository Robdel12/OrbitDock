# OrbitDock Swift Client

This is the SwiftUI client for OrbitDock on macOS and iOS.

It is an endpoint-aware UI over a server-authoritative system:

- the Rust server owns durable session state and business rules
- the client renders that state, sends user intent, and manages local presentation
- REST handles client-initiated reads and mutations
- WebSocket handles server-pushed events and real-time session interaction

## Where Things Go

- `OrbitDockNative/OrbitDock/Views/` contains feature UI
- `OrbitDockNative/OrbitDock/Services/Server/` contains endpoint runtimes, typed transport clients, and session orchestration
- `OrbitDockNative/OrbitDock/Models/` contains app-facing domain and view data
- `OrbitDockNative/OrbitDock/Navigation/` contains routing and app shell navigation state
- `OrbitDockNative/OrbitDock/Platform/` contains OS-specific glue

If a new feature needs durable session truth, change the server contract first. The client should not infer server-owned business state from history.

## Architecture Docs

- [docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md) is the source of truth for client layer boundaries, state ownership, and coordination rules
- [docs/data-flow.md](../docs/data-flow.md) is the transport contract for HTTP bootstrap, mutation responses, and WebSocket follow-up
- [orbitdock-server/docs/API.md](../orbitdock-server/docs/API.md) is the source of truth for the HTTP and WebSocket contract
- [docs/GETTING_STARTED.md](../docs/GETTING_STARTED.md) covers local setup, build commands, and development workflow

## Testing

Client tests should follow the same bar we used for the server:

- test user outcomes, not internal call order
- prefer pure helpers and deterministic state transitions
- use integration-style tests at real transport boundaries
- avoid UI tests unless a workflow truly requires them
- avoid arbitrary sleeps and polling

That means most client coverage should live in `OrbitDockNative/OrbitDockTests/`, with unit tests for pure policy helpers and integration-style tests for transport, stores, and runtime coordination.
