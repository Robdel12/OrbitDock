# Engineering Guardrails

Use this doc for the architectural rules that should shape most code changes.

This is the stuff that's easy to violate quietly and expensive to untangle later.

## Server-Authoritative State

The Rust server owns durable session and approval truth.

The Swift client should render server state, not reconstruct business logic by scanning history or guessing queue state. If the client needs new durable truth, change the server contract.

## REST And WebSocket Split

Default to REST for client-initiated reads and mutations.

Use WebSocket for:

- subscriptions
- streaming turn interaction
- server-pushed real-time events

If a REST mutation needs to notify other clients, let the server broadcast the result afterward. Do not send the mutation itself over WebSocket just because a broadcast follows.

### WS Events Are Triggers, Not State

WebSocket events tell the client **something changed**. They are not a data pipeline for view model state.

When a WS event arrives (approval requested, config changed, session status), the client should re-fetch the owning HTTP snapshot and apply it as the single source of truth. Do not bridge WS event payloads directly into view model properties — that creates a parallel state tree that drifts from the server and causes bugs where the UI shows stale or missing state until the user navigates away and back.

The only exception is conversation row deltas, which carry server-assigned sequence numbers and are applied incrementally by design.

## Typed Protocol Boundaries

Keep the Swift side strongly typed to match Rust serde models.

- do not introduce `AnyCodable` for payloads that have a real schema
- keep unknown server message variants resilient so the connection does not crash on forward-compatible changes
- prefer explicit typed payloads over generic bags of fields

When in doubt, read:

- [data-flow.md](data-flow.md)
- [SWIFT_CLIENT_ARCHITECTURE.md](SWIFT_CLIENT_ARCHITECTURE.md)

## SQLite Ownership

Only the Rust server reads from and writes to SQLite directly.

The app and CLI should go through server APIs. If a workflow needs direct DB access to function, that is usually a design smell.

## Conversation Row Persistence

Conversation row writes must follow the server's single-writer path.

Do not introduce side paths that write rows directly and race sequence assignment. This is one of the easiest ways to create subtle ordering bugs.

For the detailed persistence model, read [database-and-persistence.md](database-and-persistence.md).

## State Scoping In Swift

Scope cached or mutable state by session or path identity so data does not bleed across sessions.

Guard async callbacks with identity checks when the user can change selection or endpoint while work is in flight.

For deeper client guidance, read:

- [CLIENT_DESIGN_PRINCIPLES.md](CLIENT_DESIGN_PRINCIPLES.md)
- [SWIFT_CLIENT_ARCHITECTURE.md](SWIFT_CLIENT_ARCHITECTURE.md)

## Theme And UI System

Use OrbitDock theme tokens and palette values, not system colors or one-off sizing values.

Important constraints:

- do not use `.foregroundStyle(.tertiary)` or `.foregroundStyle(.quaternary)` on the dark theme
- use the explicit text color tokens instead
- keep spacing, radius, type, shadow, and motion on the shared design tokens

For broader UI rules, read:

- [design-system.md](design-system.md)
- [typography.md](typography.md)

## Rust Clippy Policy

Do not add `#[allow(clippy::...)]` without explicit approval.

When Clippy flags a design issue, fix the design instead of muting the warning.

Common examples:

- `too_many_arguments` → introduce a params struct
- `large_enum_variant` → box the large variant
- `type_complexity` → add a type alias

## Keep Rules Focused

If a rule is too detailed for a quick read, move it into a focused doc and link it from here.

The goal is durable guidance, not a giant pile of facts.
