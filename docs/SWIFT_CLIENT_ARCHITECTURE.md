# Swift Client Architecture

This doc captures the long-lived shape of the OrbitDock Swift client.

The short version:

- `SessionStore` is the transport and recovery shell.
- feature services own reusable business behavior.
- view models own screen-level orchestration and state.
- views stay dumb and render what the model layer gives them.

## Layer Ownership

### `SessionStore`

`SessionStore` owns:

- the server connection and event listener lifecycle
- session subscription and recovery
- HTTP bootstrap hydration and websocket reconciliation
- per-session observable registries
- thin wiring that applies authoritative server responses to local observables

`SessionStore` does not own:

- feature-specific business rules
- screen-specific orchestration
- new command entry points
- recovery heuristics that belong to a feature model

If a change needs product logic, put that logic in the owning feature service or view model and let `SessionStore` remain the shell around transport and recovery.

### Feature Services

Feature services own reusable behavior that is not a view concern.

Examples:

- `WorktreeService`
- `CapabilitiesService`
- `CodexAccountService`

These services should talk to typed API clients directly when possible. If they need `SessionStore`, it should be for observable state access or transport coordination, not as a place to add new behavior.

### View Models

View models own:

- user intent handling
- loading and error state
- derived UI state
- choosing when to call a service or store method

If a behavior is only meaningful for one screen, it belongs in that screen’s view model.

### Views

Views should stay declarative.

They should render state, forward gestures, and avoid owning cross-cutting business logic.

## Mutation Flow

Preferred flow:

1. A view model receives user intent.
2. The view model calls a feature service or a narrow store entry point.
3. The service or store calls the typed server client.
4. The authoritative response is applied to local observable state.
5. websocket events reconcile any remaining drift.

This keeps server truth authoritative while avoiding store bloat.

## Compatibility Rule

When a legacy store method is still needed during migration:

- keep it thin
- mark it clearly as compatibility-only
- do not build new product logic on top of it
- move the next real feature change into the owning service or view model

