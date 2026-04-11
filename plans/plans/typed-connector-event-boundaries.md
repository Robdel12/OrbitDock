# Typed Connector Event Boundaries

Date: 2026-04-11
Status: Implemented

## Progress Update
- [x] Phase 1 landed in `connector-core`: shared typed lanes exist and reducer conversion now accepts only `ConnectorStateEvent`.
- [x] Phase 2 is functionally landed in the server runtime: Claude and Codex session loops now consume `ConnectorOutput` and route through the shared dispatcher before any reducer call.
- [x] Phase 3 is landed: Claude and Codex connector internals now emit typed `ConnectorOutput` lanes directly, without the legacy mixed `ConnectorEvent` bridge in the touched connector paths.
- [x] Follow-up simplification pass landed: shared watchdog/error plumbing was centralized, Claude/Codex loop branches were flattened, and repeated row persist/update glue was reduced.
- [x] Tool PTY lifecycle is cleaner across server and native client: subscribe validates `session_id`, exit is broadcast as an in-band PTY event, unsubscribe cancels the server forwarder, and completed bash cards fall back to transcript-backed output instead of stale capped replay state.
- [x] Focused verification passed for the shared runtime path and both connector crates.
- [x] Native macOS build passed after the PTY client/server cleanup.
- [x] Brittle source-scan tests were replaced with direct behavior tests around typed outputs.
- [ ] Live manual Claude runtime repro is still worth running after restart, but it is no longer blocked on connector event-typing debt.

## Context
- OrbitDock currently uses one `ConnectorEvent` enum for durable conversation/state events, runtime directives, and transport side effects.
- `connector-core` explicitly marks some variants as invalid for the reducer and panics with `unreachable!()` if they arrive there.
- Codex intercepts out-of-band variants like `DynamicToolCallRequested` and `ToolPty*` before reduction, but Claude does not.
- The latest Claude crash was triggered by a resumed Claude turn that emitted a bash tool event, which the Claude loop forwarded into the reducer.

## Why This Change
- Problem:
  The system depends on each provider loop remembering which variants must be intercepted out-of-band.
- Why now:
  Claude is still crashing in production flows, and the failure is architectural rather than provider-specific.
- Cost of leaving it as-is:
  Every new provider feature or side-channel event can silently become another runtime crash path.
- Success looks like:
- [ ] The reducer cannot accept PTY, dynamic-tool, hook-session, or similar out-of-band events by type.
- [x] Claude and Codex both route provider outputs through the same typed contract without provider-specific drift.
- [~] A Claude bash tool run should no longer crash the session runtime; the architectural crash path is removed and covered in focused tests, but a fresh live runtime repro is still pending.

## Target Design

### Current Gap
- `transition::Input::from(ConnectorEvent)` accepts a broad enum and relies on runtime `unreachable!()` for invalid variants.
- Provider session loops contain ad hoc filtering logic instead of compiling against a strongly typed boundary.
- Runtime side effects and durable state updates are mixed in one channel, so multi-provider correctness depends on convention.

### Proposed Shape
- Introduce a typed connector output boundary in `connector-core` with three lanes:
  - `ConnectorStateEvent` for reducer-safe, durable session state transitions.
  - `ConnectorRuntimeDirective` for orchestration actions such as dynamic tool calls and hook-session ownership updates.
  - `ConnectorTransportEffect` for transport-only side effects such as tool PTY lifecycle/output.
- Replace `impl From<ConnectorEvent> for transition::Input` with a conversion that only accepts `ConnectorStateEvent`.
- Add one shared runtime dispatcher in the server that handles the three lanes explicitly before any reducer call.
- Make provider connectors translate raw provider output into the typed boundary, so provider loops forward `ConnectorOutput` instead of filtering raw mixed events.
- Preserve the existing session-runtime panic shield as a fallback, but remove panic-based correctness from normal provider data flow.

### Risks And Mitigations
| Risk | Why it matters | Mitigation |
|---|---|---|
| Refactor touches both providers and shared core | Drift during migration could break one provider while fixing the other | Introduce the typed boundary in `connector-core` first, then migrate Codex and Claude behind the same dispatcher |
| Too much churn in one pass | The current mixed enum is used broadly | Use an additive migration: add typed outputs first, adapt server loops, then retire impossible mixed-event paths |
| Hidden out-of-band variants remain | Another panic could survive the refactor | Audit all non-reducer events in `ConnectorEvent`, move them into directive/effect lanes, and add compile-time exhaustiveness checks |

## Phase 1: Define Typed Output Lanes
Goal: Make reducer-safe versus out-of-band connector output explicit in shared core types.
Why this phase first: The server cannot be made robust until the contract is explicit and compiler-enforced.
Files:
- `orbitdock-server/crates/connector-core/src/lib.rs` - add typed connector output enums/structs
- `orbitdock-server/crates/connector-core/src/transition.rs` - narrow reducer input conversion to reducer-safe events only
- `orbitdock-server/crates/connector-core/src/panic.rs` or adjacent shared modules - move any panic-only guards behind typed APIs if needed

Changes:
- [x] Define `ConnectorOutput` with separate state-event, runtime-directive, and transport-effect variants.
- [x] Define `transition` conversion only for `ConnectorStateEvent`.
- [x] Remove `unreachable!()` as the normal guard for provider-originated out-of-band variants.

Done when:
- [x] It is impossible to call the reducer with `ToolPty*`, hook-session, or dynamic-tool events by type.
- [x] `connector-core` compiles with exhaustive handling of all connector output classes.

## Phase 2: Move Server Runtime To A Shared Dispatcher
Goal: Give Claude and Codex one shared, explicit dispatch path for typed connector outputs.
Why this phase next: Once the contract is typed, the server must consume it uniformly across providers.
Files:
- `orbitdock-server/crates/server/src/runtime/session_command_handler.rs` - add shared dispatch helpers for state events, directives, and transport effects
- `orbitdock-server/crates/server/src/connectors/claude_session.rs` - replace ad hoc forwarding with typed dispatch
- `orbitdock-server/crates/server/src/connectors/codex_session.rs` - migrate existing special-case handling onto the same shared dispatcher
- `orbitdock-server/crates/server/src/infrastructure/tool_pty.rs` - keep PTY side effects behind the transport-effect handler only

Changes:
- [x] Add a shared runtime dispatcher that handles each typed lane explicitly.
- [x] Route Claude and Codex through that same dispatcher.
- [x] Remove provider-loop knowledge of reducer-invalid variants where the shared dispatcher now owns the distinction.

Done when:
- [x] Claude and Codex session loops no longer contain divergent special-case filtering for mixed connector events.
- [x] PTY and dynamic-tool side effects are handled without any reducer entry.

## Phase 3: Migrate Connectors And Lock In Behavior
Goal: Make provider connectors emit typed outputs and verify the crash path is gone.
Why this phase next: The provider boundary is the last place mixed events can leak from.
Files:
- `orbitdock-server/crates/connector-claude/src/lib.rs` - emit typed outputs for bash PTY, approvals, hook-session, and state events
- `orbitdock-server/crates/connector-codex/src/...` - align Codex event emission with the typed output boundary
- `orbitdock-server/crates/server/tests/...` or provider-specific integration tests - add cross-provider regression coverage

Changes:
- [x] Update Claude connector emission to use the typed output boundary directly.
- [x] Update Codex connector emission to the same boundary.
- [x] Replace brittle source-scanning coverage with behavior tests that assert typed output lanes and reducer-safe outcomes.

Done when:
- [~] A resumed Claude session can hit a bash tool request without crashing or downgrading to resumable.
- [x] Provider tests prove reducer-invalid events are consumed outside the reducer.

## Files To Modify
| File | Planned change |
|---|---|
| `orbitdock-server/crates/connector-core/src/lib.rs` | Define typed connector output boundary |
| `orbitdock-server/crates/connector-core/src/transition.rs` | Restrict reducer conversion to state events |
| `orbitdock-server/crates/server/src/runtime/session_command_handler.rs` | Add shared typed dispatcher |
| `orbitdock-server/crates/server/src/connectors/claude_session.rs` | Remove mixed-event forwarding and use typed dispatch |
| `orbitdock-server/crates/server/src/connectors/codex_session.rs` | Align with shared typed dispatch |
| `orbitdock-server/crates/connector-claude/src/lib.rs` | Emit typed outputs instead of mixed `ConnectorEvent` traffic |
| `orbitdock-server/crates/connector-codex/src/...` | Align provider emission with typed output lanes |
| `orbitdock-server/crates/server/src/infrastructure/tool_pty.rs` | Remain transport-effect-only, never reducer-driven |

## Implementation Order
1. Define the typed boundary in `connector-core` and make reducer-safe conversion the only compile path.
2. Add the shared server dispatcher and migrate Codex and Claude loops to it.
3. Update provider connectors to emit typed outputs directly, then remove leftover mixed-event paths.
4. Add regressions for Claude bash PTY flow and cross-provider non-reducer events.

## Verification
Build or test commands:
- `cargo check -p orbitdock-connector-core`
- `cargo check -p orbitdock-server`
- `cargo test -p orbitdock-server connector` 
- `cargo test -p orbitdock-connector-claude -- --test-threads=1`

Checks:
- [x] Reducer-facing code no longer compiles if handed a PTY or runtime-directive event.
- [ ] Resuming `od-3172be7c-7db6-4403-a14e-3f566611e703` or an equivalent Claude session no longer crashes on the first bash tool.
- [x] Codex PTY and dynamic-tool flows still work after the shared dispatcher migration.
- [x] Runtime panic shielding stays as a fallback, but no longer carries correctness for this class of provider event.

Verified in this pass:
- [x] `cargo check -p orbitdock-server`
- [x] `cargo test -p orbitdock-server session_command_handler -- --test-threads=1`
- [x] `cargo test -p orbitdock-server tool_pty -- --test-threads=1`
- [x] `RUSTC_WRAPPER= cargo test -p orbitdock-connector-claude -- --test-threads=1`
- [x] `RUSTC_WRAPPER= cargo test -p orbitdock-connector-codex -- --test-threads=1`
- [x] `rg -n "ConnectorEvent|into_output\\(|Vec<ConnectorEvent>" crates/connector-codex/src crates/connector-claude/src`
- [x] `xcodebuild -project OrbitDockNative/OrbitDock.xcodeproj -scheme OrbitDock -destination 'platform=macOS' build`

## Definition Of Done
- [x] The connector boundary is strongly typed across providers.
- [x] Reducer-invalid events are impossible to route into `transition::transition` by design.
- [~] Claude no longer crashes on bash/PTy-capable tool flows.
- [x] Codex and Claude share one dispatch model instead of provider-specific filtering logic.
- [x] Regression tests cover the typed-output failure mode that caused this crash class.
