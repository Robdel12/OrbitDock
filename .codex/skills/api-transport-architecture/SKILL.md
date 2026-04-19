---
name: api-transport-architecture
description: "Use when designing or changing OrbitDock API and transport flow. Enforces the scaling contract: HTTP for bootstrap, pagination, mutations, and other heavy payloads; WebSocket for light realtime deltas, replay, heartbeats, and refetch hints only. Prevents overloaded sockets, god-object stores, and client-side business-state inference."
---

# API Transport Architecture

Use this skill when touching any of these areas:

- Rust HTTP or WebSocket transport
- Rust protocol contracts
- Swift client networking, stores, reconnect logic, or bootstrap flow
- dashboard, missions, detail, composer, conversation, or any new large UI surface
- API design for features that need to scale to many concurrent agents

## Core Contract

- HTTP owns bootstrap, heavy reads, pagination, and mutation responses.
- WebSocket owns light realtime deltas, replay, heartbeats, and explicit refetch hints.
- The Rust server owns durable business truth.
- The client renders server state and derives presentation only.

Reserve `control plane` for runtime endpoint selection, primary-claim routing, and sync topology only.
Do not create UI-facing endpoints like `/api/control-plane`; model those as normal REST resources such as sessions, conversations, capabilities, dashboard, missions, or library.
Do not use `control plane` as the name of a UI-facing HTTP surface when the surface is really a compact sessions summary.

If a payload is large, expensive to build, expensive to decode, or likely to be needed only on demand, it belongs on HTTP.

## Scale-First Rules

Design for hundreds of concurrent agents without stressing the UI thread, server transport, or reconnect path.

- Do not treat WebSocket like a catch-all state pipe.
- Do not push large snapshots repeatedly over WS.
- Do not rebuild whole screens or global projections for every small event.
- Do not make one store or object responsible for every surface in the app.
- Prefer narrow, surface-local updates and explicit refetch over broad invalidation storms.

## Server Authority Rules

- Durable business fields stay on the Rust server.
- The client must not infer business truth from connector internals, channel presence, or transcript heuristics.
- Persist lifecycle or control changes through explicit domain transitions.
- SQLite is the durable source of truth for server-owned state.

## Surface Rules

Treat major UI areas as named surfaces, not one catch-all blob.

Examples:

- dashboard
- missions
- session detail
- session composer
- conversation

For each surface:

1. load the HTTP snapshot
2. store the returned revision
3. subscribe to WS with `since_revision`
4. if replay gaps, refetch only that HTTP surface

## Mutation Rules

- Successful `POST`/`PATCH`/`PUT` responses are authoritative and should be applied immediately.
- WebSocket reconciles afterward.
- Never persist or broadcast an accepted row before the underlying server action has actually succeeded.

## WebSocket Budget

WebSocket messages should usually be one of these:

- small delta
- replay event
- heartbeat
- subscription ack
- refetch/resync hint
- lightweight surface invalidation event

Be suspicious of any WS message that contains:

- full dashboard payloads
- full mission payloads
- full conversation history
- expanded heavy content that could be fetched on demand
- broad cross-surface state bundles

## Anti-Patterns

Do not introduce:

- dual bootstrap paths for the same surface
- UI component names leaking into API or transport names
- large snapshot payloads over WS for normal bootstrap
- client-side business-state inference
- god-object stores that recompute every screen from one broad state blob
- “accept first, fail later” mutation flows that create ghost state
- dead compatibility branches with `allow(...)` suppressions instead of deleting obsolete code
- mixed API clients that combine unrelated responsibilities like app-shell summary reads and server-role mutations

## Review Checklist

- Is HTTP the only bootstrap/heavy-read path here?
- Is WS carrying only light realtime/replay/refetch-hint behavior?
- Is the server, not the client, deciding business state?
- Is the change surface-local instead of globally invalidating unrelated views?
- If replay gaps happen, does the client refetch the exact HTTP surface?
- If a mutation succeeds, is the response applied immediately?
- Would this still feel cheap with hundreds of concurrent agents?

## References

- Read [docs/data-flow.md](../../../docs/data-flow.md) for the shared contract and diagrams.
- Read [docs/ARCHITECTURE.md](../../../docs/ARCHITECTURE.md) for scene ownership and surface boundaries.
- Use the `rust-server-architecture` skill alongside this one for server implementation work.
