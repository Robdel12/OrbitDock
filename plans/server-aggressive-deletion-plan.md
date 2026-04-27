# Server/API Aggressive Deletion Plan

Date: 2026-04-26

Basis: [server-api-line-audit.md](server-api-line-audit.md)

## Context

- The server/API surface is large enough that splitting files alone would be a trap: `orbitdock-server` is 142,533 counted lines across 441 files, with 122,855 Rust lines across 370 Rust files.
- Inline Rust tests are not the release-binary problem. The normal build excludes `#[cfg(test)]` modules/items and test harness code, but inline tests still inflate source files, editor navigation, review noise, and test compile time.
- The deletion target should be whole concepts first, then duplicate compatibility paths, then implementation-detail tests, then refactors of the remaining production code.
- Migrations are immutable history. Do not delete or edit existing `migrations/V*.sql` files as part of this cleanup.

## Why This Change

The current codebase has accumulated parallel paths: direct/passive connector behavior, protocol compatibility fields, REST and WebSocket overlap, CLI/admin surfaces, sync/outbox infrastructure, and many test blocks that lock implementation shape instead of user outcomes.

Success is not “fewer files.” Success is fewer concepts to reason about:

- A smaller server binary surface.
- Fewer runtime paths for creating, resuming, steering, and syncing sessions.
- Protocol structs grouped by active product surface, not historical convenience.
- Tests that prove durable user-visible behavior without preserving dead architecture.
- A line-count reduction that comes from deletion before rearrangement.

## Hard Guardrails

- Do not delete migration history.
- Do not delete persistence code for data that still exists in supported local databases unless there is a replacement migration and restore story.
- Do not delete tests simply because they are inline; delete or rewrite tests only when the behavior is covered at a better level or the feature is gone.
- Do not collapse server-authoritative state back into client inference.
- Do not remove REST endpoints that the native app still calls unless the native client is changed in the same branch.
- Do not remove WebSocket events that active UI flows subscribe to unless a REST refetch path or event replacement is explicit.

## Rust Test Answer

Rust does not include normal `#[cfg(test)] mod tests` blocks in regular `cargo build` or release builds. Those modules are compiled only for test builds. Standalone files like `src/tests.rs` are also excluded when they are imported behind `#[cfg(test)] mod tests;`.

So same-file tests are idiomatic and not a shipping-binary mistake. The real issue here is maintainability: a 4,412-line reducer with 1,500+ lines of tests is still hard to review, even if the tests disappear from release builds.

## Deletion Scoring

Before deleting any area, score it against these checks:

- [ ] No active native API client call uses it.
- [ ] No HTTP route or WebSocket handler exposes it.
- [ ] No CLI command depends on it.
- [ ] No persisted database state requires it for startup restore, hydration, or migration compatibility.
- [ ] No connector/runtime path calls it in the direct-session happy path.
- [ ] No user-visible workflow loses coverage without a replacement test.
- [ ] Removing it reduces a concept, not merely a file.

## Phase 1: Prove Active Surface Area

Objective: build a route/command/type map so deletion is evidence-based.

- [ ] Generate an HTTP route inventory from `orbitdock-server/crates/server/src/transport/http/router.rs` and subrouters.
- [ ] Generate a WebSocket message inventory from `orbitdock-server/crates/server/src/transport/websocket/router.rs` and `handlers/`.
- [ ] Generate a native API call inventory from `OrbitDockNative/OrbitDock/Services/Server/API/`.
- [ ] Generate a CLI command inventory from `orbitdock-server/crates/cli/src/commands/`.
- [ ] Cross-reference protocol structs in `orbitdock-server/crates/protocol/src/types.rs`, `client.rs`, and `server.rs` against server and native usage.

Done when every route/message/command/type is tagged as `active`, `compatibility`, `test-only`, or `delete-candidate`.

## Phase 2: Remove Test-Only and Implementation-Detail Drag

Objective: reduce review complexity without weakening confidence.

Candidates from the audit:

- `orbitdock-server/crates/connector-core/src/transition.rs` has tests starting around line 2857 with 46 test cases.
- `orbitdock-server/crates/connector-codex/src/app_server.rs` has tests starting around line 2634.
- `orbitdock-server/crates/server/src/infrastructure/persistence/tests.rs` is 1,756 lines.
- `orbitdock-server/crates/server/src/infrastructure/persistence/mission_control.rs` has tests starting around line 495.
- `orbitdock-server/crates/server/src/runtime/session_command_handler.rs` has tests starting around line 967.

Tasks:

- [ ] Move large inline test blocks to sibling `*_tests.rs` modules gated by `#[cfg(test)]` when they are still valuable.
- [ ] Delete tests that only assert helper internals after replacing them with user-outcome tests at the domain/runtime/persistence boundary.
- [ ] Collapse duplicated setup builders across persistence/runtime tests.
- [ ] Keep high-value state-machine tests for pure transitions.
- [ ] Avoid deleting regression tests for historical data restore unless the supported data shape is intentionally retired.

Done when top production files are readable without scrolling through test suites, and no behavior coverage is lost without an intentional replacement.

## Phase 3: Delete Dead Compatibility and Legacy Paths

Objective: remove code that exists only for old shapes or old connector behavior.

High-signal search targets found during audit:

- `allow(dead_code)` in connector/core/session/persistence areas.
- `mixed_legacy` handling in `orbitdock-server/crates/server/src/infrastructure/persistence/usage.rs`.
- Claude direct/passive shadow-session preservation paths in persistence and connector handling.
- Test-only helper exports in `session_reads/startup_recovery.rs` and related persistence modules.

Tasks:

- [ ] Remove one `#[allow(dead_code)]` at a time and run `make rust-check` to let the compiler identify truly unused code.
- [ ] For `mixed_legacy` usage accounting, decide whether old databases must still repair that shape. If not, delete the repair path and keep a migration note.
- [ ] For Claude shadow-session compatibility, decide whether old passive shadow rows are still supported. If not, delete preservation/cleanup branches together with their tests.
- [ ] Delete test-only public helpers that exist only to pierce module boundaries; replace with boundary-level tests.

Done when no `allow(dead_code)` remains without a written reason, and compatibility branches are either deleted or explicitly documented as supported.

## Phase 4: Cut Whole Product Surfaces

Objective: get real line-count wins by removing features that are no longer strategic.

Product-decision candidates:

- CLI bulk surface: `orbitdock-server/crates/cli/src/commands/session.rs` is 2,451 lines and `cli.rs` is 1,573 lines.
- Admin/install/service flows: `admin/` is 5,315 lines.
- Mission Control server surface: domain/runtime/http/persistence files span several thousand lines.
- Daytona workspace dispatch and infrastructure.
- Linear/GitHub release infrastructure.
- WebSocket command handlers that are now REST-only by policy.
- Legacy direct Codex runtime/session paths if app-server fully owns Codex sessions.

Tasks:

- [ ] Mark each candidate as `keep`, `delete`, or `freeze`.
- [ ] For every `delete`, remove the native client, route, runtime command, persistence query/write path, protocol type, CLI command, docs, and tests in the same branch.
- [ ] For every `freeze`, stop adding new code and move tests to higher-level smoke coverage only.
- [ ] For every `keep`, name the owning layer and expected active user workflow.

Done when at least one whole surface is deleted end-to-end rather than split into smaller files.

## Phase 5: Protocol Pruning

Objective: make protocol represent current contracts only.

Targets:

- `orbitdock-server/crates/protocol/src/types.rs` at 2,911 lines.
- `orbitdock-server/crates/protocol/src/client.rs` at 1,695 lines.
- `orbitdock-server/crates/protocol/src/server.rs` at 1,002 lines.
- Native mirrors in `OrbitDockNative/OrbitDock/Services/Server/Protocol/`.

Tasks:

- [ ] Split active protocol by surface only after dead fields/types are removed.
- [ ] Delete protocol fields that are neither sent by server nor read by native.
- [ ] Delete client-to-server message variants that duplicate REST mutations.
- [ ] Prefer typed surface modules: `sessions`, `conversation`, `usage`, `permissions`, `capabilities`, `missions` only if kept.

Done when protocol modules contain active contracts, not historical aggregate types.

## Phase 6: Connector Simplification

Objective: reduce provider-specific translation to current runtime paths.

Targets:

- `orbitdock-server/crates/connector-claude/src/lib.rs` at 3,560 lines.
- `orbitdock-server/crates/connector-core/src/transition.rs` at 4,412 lines.
- `orbitdock-server/crates/connector-codex/src/app_server.rs` at 3,090 lines.
- `orbitdock-server/crates/server/src/connectors/codex_hooks/mod.rs` at 1,197 lines.
- `orbitdock-server/crates/server/src/connectors/codex_session.rs` at 964 lines.

Tasks:

- [ ] Confirm whether old direct Codex runtime/session code is still reachable now that app-server is first-class.
- [ ] Delete unreachable connector event variants before splitting files.
- [ ] Delete connector-core transition inputs/effects that no provider emits.
- [ ] Move approval preview/rendering out of the reducer only after unused preview types are deleted.
- [ ] Split Claude connector only after removing obsolete control requests and message handlers.

Done when provider connectors emit a smaller event vocabulary and the core transition reducer handles fewer cases.

## Phase 7: Transport Cleanup

Objective: enforce HTTP for heavy mutations/read payloads and WebSocket for light realtime deltas only.

Targets:

- `orbitdock-server/crates/server/src/transport/http/session_actions.rs` at 826 lines.
- `orbitdock-server/crates/server/src/transport/http/session_lifecycle/create.rs` at 489 lines.
- `orbitdock-server/crates/server/src/transport/websocket/handlers/`.
- `orbitdock-server/crates/server/src/transport/websocket/rest_only_policy.rs`.

Tasks:

- [ ] Delete WebSocket handlers for operations that are now REST-only.
- [ ] Delete HTTP response fields duplicated by subscription snapshots unless they are needed for immediate mutation results.
- [ ] Delete route-level helper DTOs that duplicate protocol/domain types without adding transport meaning.
- [ ] Keep HTTP create/session actions as thin mapping layers over runtime/domain commands.

Done when transport code maps requests and responses but does not own business state or compatibility repair.

## Verification

Run after each deletion slice:

- [ ] `make rust-check`
- [ ] `make rust-test` for affected crates/modules
- [ ] Native compile/test command for any changed Swift API contract
- [ ] API smoke test for session create, session detail, send message, subscribe, usage summary, and startup restore
- [ ] Manual database restore check if persistence or compatibility code was deleted

## Definition of Done

- [ ] At least one whole obsolete surface is removed end-to-end.
- [ ] Top 10 line-count files either shrink materially or have deletion blockers documented.
- [ ] No unsupported compatibility branch remains silently preserved.
- [ ] Remaining tests prove user-visible behavior and durable server truth.
- [ ] The line-count audit is regenerated and compared against the baseline.
