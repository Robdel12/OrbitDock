# Aggressive Hit List (Nuke + Regenerate)

We’re roughly **70%** done on transport/data foundations, but only about **45-50%** done on view/state architecture. Overall I’d call us **~60%** to the finish line.

## Progress Update (2026-04-16)

- [x] ControlDeck no longer self-subscribes to detail WS in the embedded session-detail flow.
- [x] ControlDeck refresh lifecycle now uses shared coalesced refresh scheduling (removed bespoke queue loop).
- [x] ControlDeck session rebinding now hard-resets state to prevent stale snapshot bleed across session switches.
- [x] Conversation invalidation-triggered forced-resync path now coalesces bursts and suppresses immediate re-fetch loops.
- [x] Conversation refresh lifecycle now uses shared coalesced refresh scheduling (removed bespoke queue loop).
- [x] SessionDetail now uses shared coalesced refresh scheduling (no bespoke refresh queue loop).
- [x] ReviewCanvas now uses shared coalesced refresh scheduling (no bespoke refresh queue loop).
- [x] MissionControl detail refresh now uses shared coalesced refresh scheduling (no bespoke refresh queue loop).
- [x] SessionDetail/Review invalidations now enqueue refresh work instead of serial await-looping each event.
- [x] Added regressions for ControlDeck rebind reset + conversation forced-resync coalescing.
- [x] Added regression proving SessionDetail ignores stale payload after session rebind.
- [x] Runtime endpoint lookup no longer silently falls back to active endpoint for explicit endpoint IDs.
- [x] Session end/rename mutation paths now require endpoint ownership and avoid cross-endpoint fallback routing.
- [x] Added runtime registry regressions covering explicit-missing endpoint lookup and nil-endpoint creation lookup.
- [x] ControlDeck submission routing now keys strictly off authoritative presentation mode (prevents idle sends from routing to steer + fallback new-turn duplication).
- [x] Added submission routing regressions for compose/steer/approval/disabled mode behavior.
- [x] Conversation invalidation resync now gates on revision progression (prevents repeated `conversation-resync` fetch loops for already-synced revisions).
- [x] Unversioned conversation invalidation bursts now trigger at most one forced resync per applied cursor (prevents nil-revision refresh loops).
- [x] Replaced `conversation/actions/*` and nested task/file command routes with flatter conversation command endpoints (`/conversation/{interrupt|compact|undo|rollback|stop|rewind}`) across server + native client.
- [x] SessionDetail lifecycle now relies on task-owned subscription cleanup only (removed extra `onDisappear` unsubscribe path that could desubscribe active lifecycle tasks).
- [x] Removed dead SessionDetail lifecycle planning scaffolding (`onAppear` / `onDisappear` planner artifacts) left over from the prior architecture.
- [x] ReviewCanvas now hard-resets transient cursor/collapse/comment UI state on binding identity changes so state cannot bleed across session switches.
- [x] SessionDetail diff-banner rules now live in one dedicated planner consumed by the view model (removed dead lifecycle helper coupling).
- [x] SessionDetail/Review invalidation handling now gates by authoritative revision progression (no repeated same-revision refetch churn).
- [x] Continue deleting/replacing remaining view-state roots in SessionDetail/Review per hit list.
- [x] Finish transport/runtime simplification pass across remaining session surfaces.
- [x] Conversation forced-resync no longer drops refetches immediately after row deltas (prevents “leave + return to see updates” stale timeline behavior).

1. `OrbitDockNative/OrbitDock/Views/Sessions/ControlDeck/`
Delete and rebuild as one thin screen + one state model + small presentational subviews.

2. `OrbitDockNative/OrbitDock/Views/SessionDetail/`
Delete and rebuild around a single authoritative detail snapshot + explicit tabs/sections.

3. `OrbitDockNative/OrbitDock/Views/Review/`
Delete and rebuild as one straightforward review surface with deterministic refresh flow.

4. `OrbitDockNative/OrbitDock/Services/Server/ServerSessionTransport.swift` + `ServerSessionAPI.swift` + `ServerSessionContext.swift`
Replace with one boring session runtime contract: subscribe surface, receive delta/invalidation, do one coalesced HTTP refetch.

5. `OrbitDockNative/OrbitDock/Views/Conversation/ConversationViewModel.swift`
Rewrite fully to remove remaining custom queue/refresh complexity and rely on shared refresh primitives.

6. `orbitdock-server/crates/server/src/transport/http/router.rs` + `mission_control/*` action-style endpoints
Delete action-smell routes and regenerate a pure resource REST surface.

7. `orbitdock-server/crates/server/src/transport/http/capabilities.rs`
Split and regenerate into strict, stable resource responses (`skills`, `mcp`, `permissions`, etc.), no shape drift.

8. Native protocol legacy compatibility layers
`OrbitDockNative/OrbitDock/Services/Server/Protocol/*` (legacy decode/fallback paths). Delete fallback decoding and keep one canonical schema.

9. Server legacy compatibility paths for session/control config
`orbitdock-server/crates/server/src/domain/sessions/*` + related persistence shims where legacy summaries are still carried. Remove dead compatibility branches.

10. Endpoint fallback selection behavior
`OrbitDockNative/OrbitDock/Services/Server/ServerRuntimeRegistry.swift` + `OrbitDockWindowRoot.swift` fallback resolution. Rewrite to explicit endpoint ownership only.

11. Rebuild tests around outcomes, not internals
Delete brittle per-implementation tests for rewritten areas and regenerate integration-style tests per surface.
