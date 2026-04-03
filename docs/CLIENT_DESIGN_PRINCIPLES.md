# Client Design Principles

These are the practical rules for OrbitDock’s Swift client.

## Source Of Truth

- Durable session truth lives on the server.
- The client should render and reconcile, not invent new business state.
- If the client needs new durable truth, the contract should change at the server boundary.

## Ownership

- `SessionStore` is a transport and recovery shell.
- feature services own reusable behavior.
- view models own screen-specific behavior and state.
- views should not accumulate orchestration logic.

That means new behavior should land in the feature that owns it, not in a store-wide shim.

## Store Boundaries

`SessionStore` may handle:

- subscriptions
- bootstrap hydration
- websocket reconciliation
- applying server responses to observables
- compatibility forwarding that existing callers still need

`SessionStore` should not become the default place for:

- new commands
- feature-specific mutation flows
- screen-specific heuristics
- business logic that belongs to a service or view model

## Compatibility Discipline

Legacy shims are allowed only while a migration is still in flight.

When one stays around:

- keep it thin and explicit
- annotate it so new code is discouraged from using it
- do not add new behavior underneath it
- delete it once the last caller moves

## Practical Default

If you are unsure where something belongs, prefer this split:

- transport or recovery concern -> `SessionStore`
- reusable feature behavior -> feature service
- UI orchestration or screen state -> view model
- rendering -> view

