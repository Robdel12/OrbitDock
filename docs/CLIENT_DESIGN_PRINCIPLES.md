# Client Design Principles

These are the practical rules for OrbitDock's Swift client.

## Source Of Truth

- The server owns all business state.
- Each view model owns its screen state via HTTP snapshots.
- WebSocket events are signals that trigger a re-fetch, not data to be bridged into state.
- There is no shared mutable session object. Each surface fetches and owns its own data.

## One Pattern

Every surface follows the same flow:

1. View appears → view model fetches HTTP snapshot → owns it.
2. WS subscription activates → events trigger `refresh()` → re-fetch HTTP snapshot.
3. View disappears → subscription tears down. No background state accumulation.

## Ownership

- `SessionStore` is a transport shell. It manages the WS connection and exposes change streams. It does not hold session state.
- View models own screen-specific state and orchestration.
- Views stay declarative — render state, forward gestures.

## What NOT To Build

- No shared mutable session objects (no god objects).
- No `withObservationTracking` on shared state stores.
- No WS event payloads bridged directly into view model properties.
- No feature services that wrap HTTP clients just to mutate a shared observable — view models call HTTP clients directly.
- No global event processing for surfaces that aren't on screen.

## Practical Default

If you are unsure where something belongs:

- Transport or recovery → `SessionStore`
- Screen state and orchestration → view model
- HTTP calls → typed client via `store.clients`
- Rendering → view
