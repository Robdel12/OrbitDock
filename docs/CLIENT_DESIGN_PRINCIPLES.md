# Client Design Principles

This is the short version of how we want the Swift client to feel going forward.

It exists so new work lands in the right place without us having to rediscover the architecture every few weeks.

## The Big Idea

OrbitDock is a server-authoritative system with a native client on top.

That means:

- the Rust server owns durable business truth
- the Swift client owns presentation, local interaction state, and user intent
- the client should not reverse-engineer server truth from history when the server can provide it directly

If the app needs new durable truth, change the server contract first.

## Keep Feature Homes Honest

Feature folders should describe the product, not the provider implementation detail we happened to start with.

Good:

- `Views/Sessions/`
- `Views/SessionDetail/`
- `Views/NewSession/`
- `Views/Review/`
- `Views/QuickSwitcher/`
- `Views/Settings/`

Provider-specific UI should only live under provider homes when it is truly provider-only.

Good:

- `Views/Providers/Claude/`
- `Views/Providers/Codex/`

Bad:

- shared direct-session UI living under `Views/Codex/`

## Views Should Be Shells

Large root views should mostly do three things:

- render
- bind to explicit state owners
- send intents upward

They should not become the place where we keep:

- app-wide coordination
- ad hoc state mirroring
- hidden derived business rules
- transport lookups
- duplicated geometry math

If a root view keeps growing, the next move is usually:

- extract a model/coordinator for mutable state
- extract a view-state/planner layer for derived state
- keep the root as composition

## Mutable State Needs One Owner

SwiftUI needs mutable state. That is fine.

The rule is not “be purely functional everywhere.” The rule is:

- keep shared mutable state in one explicit owner
- keep decisions and projections pure whenever possible

That usually means:

- `@Observable` stores, coordinators, and feature models own mutable shared state
- pure planners/reducers/selectors own decision logic
- actors own async coordination and serialized side effects

Avoid mirrored state across multiple views unless there is a very clear reason.

## Prefer Functional Core, Observable Shell

The best fit for this app is:

- **functional core**
  - planners
  - reducers
  - projections
  - selectors
  - layout math
  - feature semantics
- **observable shell**
  - feature models
  - stores
  - routers
  - runtime registries
- **actor / service boundary**
  - networking
  - control-plane coordination
  - long-lived async processes

That gives us code that is both Swifty and easy to test.

## Use Typed Boundaries

Avoid generic “brain” objects.

Good:

- typed server clients by capability
- feature-specific models
- explicit planner types
- endpoint-scoped stores

Bad:

- one generic API client that knows everything
- giant root views full of feature logic
- process-wide notification fan-out for app-owned coordination

## NotificationCenter Is Not The App Bus

Use `NotificationCenter` for OS integration and external bridges.

Do not use it as the default way for OrbitDock-owned features to talk to each other.

For app-internal coordination, prefer:

- shared observable state
- explicit method calls
- environment-injected dependencies with clear ownership

## Testing Principles

Client tests should follow the same bar as the server:

- test user outcomes, not implementation details
- prefer pure helper tests for rules and projections
- prefer integration-style tests at real boundaries
- do not add arbitrary sleeps or polling
- do not invent mocks for our own internal logic if a cleaner seam would make the code testable

Most bugs should be fixable by improving one of these:

- the server contract
- a feature model
- a planner / reducer / projection helper

Not by teaching the UI to guess harder.

## When In Doubt

If you are not sure where a change belongs, use this order:

1. Does the server own this truth?
2. If not, does one feature need to own mutable state for it?
3. If not, can it be a pure helper?
4. If not, is it just local view state?

That sequence keeps us out of the old trap where logic slowly leaks into giant root views.
