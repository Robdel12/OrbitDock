# Notifications V1 (Server-Driven)

> Goal: rebuild notifications as a proper system, not a patch.
> Constraint: no remote push/APNs for now.
> Freedom: breaking changes are allowed if they produce a clean architecture.

---

## Why We Are Rebuilding This

The current notification flow works, but it is stitched across view lifecycle callbacks and multiple local managers. It is easy to duplicate alerts, hard to reason about transitions, and hard to test end-to-end.

This plan moves notification decisions to the Rust server (source of truth), keeps delivery on the client (where OS permission and foreground context live), and gives users real policy controls.

---

## End State We Want

- One canonical notification event stream from the server.
- One policy engine on the server that decides when events should exist.
- One thin client delivery layer that decides how to render now (system banner, toast, both, off).
- Zero notification trigger logic in SwiftUI views.
- Full per-event user configurability (including "awaiting reply").
- Deterministic dedupe/clear behavior.
- Test coverage for transition rules and policy application.

---

## Non-Negotiables

- Server owns transition detection and dedupe.
- Client owns OS permission checks and foreground/session-focus suppression.
- Event semantics come from `attentionReason`, not collapsed `workStatus`.
- No backfill spam on app launch by default.
- Legacy notification path is deleted after cutover.

---

## Event Taxonomy (V1)

- `session.awaiting_permission`
- `session.awaiting_question`
- `session.awaiting_reply`
- `session.attention_cleared`
- `session.ended`

Each event must include:

- `event_id` (stable unique ID)
- `session_id`
- `kind`
- `created_at`
- `dedupe_key`
- `title`
- `body`
- `metadata` (optional payload like provider/tool name)

---

## Delivery Policy Model (V1)

Per event kind:

- enabled: `true|false`
- surfaces: `system | toast | both | off`
- sound: `default | none | named_sound`
- suppress_when_focused_session: `true|false`
- suppress_when_app_frontmost: `true|false`
- cooldown_seconds: integer

Global:

- master_enabled
- enable_launch_backfill

Defaults:

- permission: enabled, `both`
- question: enabled, `both`
- awaiting_reply: enabled, `system`
- suppress focused session: `true`
- suppress frontmost app: `false`
- launch backfill: `false`

---

## Phase 0: Lock The Contract

### Todos

- [ ] Finalize event kinds and payload schema.
- [ ] Finalize policy schema and default values.
- [ ] Decide where policy persists in DB and how it maps to user/workspace scope.
- [ ] Document backward-compatibility strategy (expected breaking points and migration behavior).
- [ ] Add `docs/notifications-v1-spec.md` with protocol examples.

### Complete when

- [ ] Swift and Rust teams can implement independently from the same spec.
- [ ] No open naming/schema questions remain.

---

## Phase 1: Protocol + Server Message Types

### Todos

- [ ] Add protocol message types for:
- [ ] `notification_event`
- [ ] `notification_clear`
- [ ] `notification_preferences_get`
- [ ] `notification_preferences_update`
- [ ] Add protocol roundtrip tests for all new message types.
- [ ] Add sample payload fixtures for integration tests.

### Complete when

- [ ] Protocol crate tests pass.
- [ ] Swift decoder can parse all new messages with no fallback parsing hacks.

---

## Phase 2: Server Transition Engine

### Todos

- [ ] Build a pure transition projector in server code:
- [ ] input: previous session snapshot + current session snapshot
- [ ] output: canonical notification events and clear events
- [ ] Encode one-event-per-transition rules.
- [ ] Encode no-launch-backfill by default.
- [ ] Encode clear semantics when attention resolves or session ends.
- [ ] Add deterministic dedupe key generation.
- [ ] Add unit tests for full transition matrix.

### Complete when

- [ ] Given the same input sequence, output events are always identical.
- [ ] Duplicate "finished + needs attention" emissions are impossible by construction.

---

## Phase 3: Server Policy Engine + Persistence

### Todos

- [ ] Add DB persistence for notification preferences.
- [ ] Add server-side policy resolver:
- [ ] input: event + persisted policy
- [ ] output: delivery intent (`system`, `toast`, `both`, `off`)
- [ ] Add cooldown/dedupe tracking store.
- [ ] Add server APIs/WebSocket handlers to get and update preferences.
- [ ] Add migration for default preferences.
- [ ] Add tests for policy evaluation and cooldown behavior.

### Complete when

- [ ] Server can emit pre-filtered delivery intents per event.
- [ ] Preference changes are applied immediately without restart.

---

## Phase 4: Thin Client Notification Coordinator

### Todos

- [ ] Add `NotificationCoordinatorV1` in Swift, started at app root (`OrbitDockApp`), not views.
- [ ] Subscribe to server `notification_event` + `notification_clear`.
- [ ] Route events to sinks:
- [ ] `SystemNotificationSink` (`UNUserNotificationCenter`)
- [ ] `ToastSink` (in-app toasts)
- [ ] Apply client-local suppression only:
- [ ] OS authorization status
- [ ] app frontmost state
- [ ] currently focused session
- [ ] Add durable tap routing for `session_id` deep links.
- [ ] Replace `print` failures with structured logging.

### Complete when

- [ ] `ContentView` no longer triggers notifications.
- [ ] Notifications still work when switching views/panels.

---

## Phase 5: Settings Redesign (User Controls)

### Todos

- [ ] Replace current notification settings UI with event-based controls.
- [ ] Show OS permission status (`allowed`, `denied`, `not determined`).
- [ ] Add one-click "Open System Settings" action for denied state.
- [ ] Add per-event toggles and channel selectors.
- [ ] Add per-event sound selectors.
- [ ] Add event-specific test buttons (permission/question/reply).
- [ ] Add advanced toggles (launch backfill, suppress frontmost, focused-session suppression).
- [ ] Wire settings changes to server preference updates.

### Complete when

- [ ] Every user-visible notification behavior is explainable from settings.
- [ ] No hidden behavior remains in hardcoded Swift conditionals.

---

## Phase 6: Observability + QA

### Todos

- [ ] Add structured logs in server for:
- [ ] transition detection
- [ ] policy decisions
- [ ] dedupe suppression
- [ ] clear events
- [ ] Add structured logs in Swift for:
- [ ] permission checks
- [ ] delivery attempts/results per sink
- [ ] route/deep-link handling
- [ ] Add test suite coverage:
- [ ] protocol tests (Rust + Swift decode)
- [ ] server transition matrix tests
- [ ] server policy tests
- [ ] Swift integration tests with fake notification sinks
- [ ] Write a manual QA checklist for all event kinds and suppressions.

### Complete when

- [ ] We can explain every dropped/delivered notification from logs.
- [ ] Test failures catch behavior regressions before UI manual testing.

---

## Phase 7: Cutover + Cleanup

### Todos

- [ ] Gate V1 with a temporary feature flag for rollout safety.
- [ ] Enable V1 by default after validation pass.
- [ ] Delete legacy trigger paths:
- [ ] `ContentView` notification trigger logic
- [ ] legacy `NotificationManager` transition logic
- [ ] duplicated toast dedupe logic that conflicts with V1
- [ ] Remove obsolete preference keys.
- [ ] Update docs and architecture diagrams.

### Complete when

- [ ] Only V1 path exists in production code.
- [ ] No dead notification code remains.

---

## File-Level Implementation Map (Expected)

Rust:

- `orbitdock-server/crates/protocol/src/types.rs`
- `orbitdock-server/crates/protocol/src/client.rs`
- `orbitdock-server/crates/server/src/transition.rs`
- `orbitdock-server/crates/server/src/websocket.rs`
- `orbitdock-server/crates/server/src/persistence.rs`
- `orbitdock-server/crates/server/src/hook_handler.rs`

Swift:

- `OrbitDock/OrbitDock/OrbitDockApp.swift`
- `OrbitDock/OrbitDock/Services/Server/ServerProtocol.swift`
- `OrbitDock/OrbitDock/Services/Server/ServerConnection.swift`
- `OrbitDock/OrbitDock/Services/Server/ServerAppState.swift`
- `OrbitDock/OrbitDock/Services/NotificationCoordinatorV1.swift` (new)
- `OrbitDock/OrbitDock/Views/SettingsView.swift`
- `OrbitDock/OrbitDock/ContentView.swift` (remove legacy triggers)

---

## Risks We Accept Up Front

- We will break old preference compatibility if needed.
- We will break old notification internals to remove ambiguity.
- We will prioritize deterministic architecture over incremental patching.

---

## Ship Checklist

- [ ] Spec accepted
- [ ] Protocol shipped
- [ ] Server transition + policy shipped
- [ ] Client coordinator shipped
- [ ] Settings shipped
- [ ] Tests + QA pass
- [ ] Legacy path removed

