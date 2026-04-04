# Swift Client Architecture

Each route owns its state. No shared mutable session objects.

## The Rule

Every UI surface follows one pattern:

1. **HTTP snapshot** on view appear — the view model fetches its data and owns it.
2. **WS subscription** while the view is on screen — events trigger a re-fetch, not a state mutation.
3. **View model is the single source of truth** for that surface.

When the user navigates away, the subscription tears down. No background state accumulation.

## Surface Model

Each screen maps to one view model and one HTTP snapshot:

| Surface | HTTP Source | WS Trigger |
|---------|-----------|------------|
| Dashboard | `GET /api/dashboard` | `dashboardInvalidated` |
| Library | `GET /api/library` | `dashboardInvalidated` |
| Mission Control | `GET /api/missions` | `missionsInvalidated` |
| Session Detail | `GET /api/sessions/{id}/detail` | `sessionDelta`, `sessionEnded` |
| Control Deck | `GET /api/sessions/{id}/control-deck` | `sessionDelta`, `approvalRequested`, `tokensUpdated` |
| Conversation | `GET /api/sessions/{id}/conversation` | `conversationRowsChanged` (data-carrying exception) |
| Skills/MCP | `GET /api/sessions/{id}/skills`, `/mcp/tools` | `skillsList`, `mcpToolsList` |
| Review Canvas | `GET /api/sessions/{id}/diffs` | `turnDiffSnapshot`, `reviewComment*` |

## WS Event Rules

- **Signals, not state.** A WS event tells the client *something changed*. The client re-fetches the HTTP snapshot.
- **One exception: conversation row deltas.** These carry server-assigned sequence numbers and are applied incrementally. This is the only place WS carries data into a view model.
- **Per-surface subscriptions.** Each surface subscribes to the events it cares about when the view appears, and tears down when it disappears. No global subscription processing events for surfaces that aren't on screen.

## Global WS

One lightweight global WS connection handles infrastructure events only:

- `connectionStatusChanged` — triggers reconnect/recovery
- `error` — server error handling and resync
- `serverInfo` — server metadata
- `modelsList` — global model catalog
- `revision` — revision tracking for replay

These are not per-surface. They affect the transport layer, not UI state.

## What Does NOT Exist

- No `SessionObservable` — no shared mutable object holding all session state.
- No `SessionStateProjection` — no layer that applies server snapshots to a shared object.
- No `SessionControlStateReducer` — no state machine processing WS events into transitions.
- No `CapabilitiesService` — view models call HTTP clients directly.
- No `withObservationTracking` on shared objects — view models own their state.

## `SessionStore` Role

`SessionStore` is a thin transport shell:

- Manages the WS connection lifecycle
- Exposes `sessionChanges(for:)` — an `AsyncStream<Void>` per session that yields when any WS event arrives
- Exposes `conversationRowChanges(for:)` — an `AsyncStream<ConversationRowDelta>` per session for row deltas
- Exposes typed HTTP clients via `store.clients`
- Handles connection recovery and session re-subscription

`SessionStore` does NOT:

- Hold session state
- Mutate shared observables
- Own feature logic
- Decide what UI should show

## Mutation Flow

1. View model receives user intent (tap, submit, config change).
2. View model calls the typed HTTP client (`store.clients.controlDeck.updateConfig(...)`)
3. The HTTP response is the authoritative state — view model applies it as the new snapshot.
4. WS events reconcile any remaining drift via the next refresh cycle.

## View Model Pattern

```swift
@Observable
final class SurfaceViewModel {
  var snapshot: SurfaceSnapshot?

  func refresh() async {
    // Coalesce: skip if already refreshing, queue one more
    let payload = try await store.clients.surface.fetch(sessionId)
    // Revision guard: never regress
    guard payload.revision >= (snapshot?.revision ?? 0) else { return }
    snapshot = SurfaceMapper.map(payload)
  }
}

// In the view:
.task(id: sessionId) {
  viewModel.bind(...)
  await viewModel.refresh()
}
.task(id: sessionId + ":ws") {
  let (stream, _) = store.sessionChanges(for: sessionId)
  for await _ in stream {
    await viewModel.refresh()
  }
}
```
