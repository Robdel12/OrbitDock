# Direct Session Token Tracking Plan

Date: 2026-04-11
Status: Active
Supersedes: `plans/usage-reconciliation-plan-2026-04-04.md`

## Context
- OrbitDock already has a durable usage stack: `usage_events`, `usage_session_state`, `usage_turns`, and `usage_ledger_entries`.
- The server now writes completed-turn usage independently of diff presence through `PersistCommand::TurnDiffInsert`, and persistence always upserts `usage_turns` and `usage_ledger_entries` even when `diff` is `None`.
- The client now understands `snapshot_kind` semantics (`context_turn`, `mixed_legacy`, etc.) for live token display and turn-diff decoding.
- We only care about OrbitDock direct sessions for this work.
- We want token tracking that is correct per turn, durable, restart-safe, and ready for eventual conversation-view usage UI.

## Why This Change
- Problem:
  - Codex direct sessions still use `ContextTurn` snapshots for live token updates, but the completed-turn persistence path still writes per-turn usage from accumulators that are only updated for `MixedLegacy` snapshots.
  - `/api/usage/summary` still aggregates all sessions instead of only direct sessions.
  - Conversation APIs still expose per-turn token data only through `turn_diffs`, which means usage-only turns without diffs are not a first-class surface.
- Why now:
  - The current API/client refactors give us clean HTTP surfaces and clearer token semantics, so this is the right moment to finish the accounting model instead of layering more UI on top of incorrect data.
- Cost of leaving it as-is:
  - Codex-heavy direct sessions can still persist zero or incorrect per-turn usage.
  - Usage summary can still over-count scope by including non-direct sessions.
  - We cannot confidently build per-turn usage into conversation UI without a dedicated contract.
- Success looks like:
- [ ] Every completed direct-session turn produces correct billable usage regardless of provider.
- [ ] `/api/usage/summary` reports direct-session-only totals.
- [ ] A dedicated HTTP contract exists for per-turn usage history, independent of diffs.
- [ ] Live token UI and authoritative billing data are explicitly separated in the design.

## Target Design

### Current Gap
- `Input::TokensUpdated` in `connector-core` treats `MixedLegacy` as special and updates per-turn accumulators, but all other snapshot kinds overwrite only `state.token_usage`.
- Codex direct sessions emit `ContextTurn` from `last_token_usage`, which is appropriate for live context display, but not sufficient as the only source of authoritative completed-turn accounting.
- Summary SQL in `server_meta.rs` does not scope to direct sessions.
- Session/conversation hydration builds turn token data from `turn_diffs` joins, not from a usage-first turn history surface.

### Proposed Shape
- Separate the system into two server-owned flows:
  - Live token snapshots: provider-semantic `TokensUpdated` values used for session/control-deck display.
  - Completed-turn accounting: provider-normalized per-turn usage facts written once per completed turn and used by summary/history APIs.
- For provider accounting:
  - Claude direct continues using accumulated per-turn values derived from `MixedLegacy` snapshots.
  - Codex direct should finalize turn usage from a provider-appropriate completed-turn source, not from the current `ContextTurn` accumulator path.
- HTTP remains the source of truth for usage surfaces:
  - `/api/usage/summary` becomes direct-session scoped.
  - Add a dedicated per-turn usage endpoint for session history / eventual conversation usage UI.
- WebSocket remains lightweight:
  - Existing `tokens_updated` remains live UI state.
  - If needed later, WS should emit a refetch hint for per-turn usage instead of streaming large history payloads.

### Decision Log
- 2026-04-11: Treat live token snapshots and authoritative completed-turn accounting as separate concerns. Status: decided.
- 2026-04-11: Use HTTP, not WebSocket, for per-turn usage history. Status: decided.
- 2026-04-11: Scope usage summary to direct sessions only. Status: decided.
- 2026-04-11: Supersede the 2026-04-04 plan because the repo has already completed the earlier diff-decoupling work. Status: decided.

### Risks And Mitigations
| Risk | Why it matters | Mitigation |
|---|---|---|
| We patch Codex by reusing live `ContextTurn` values for billing | Could preserve wrong per-turn accounting under a cleaner API | Define a dedicated Codex turn-final accounting path and test it against provider semantics |
| We overload `turn_diffs` again instead of creating a usage-first API | Conversation usage UI remains sparse/incomplete for no-diff turns | Add a dedicated `/usage/turns` style endpoint and keep diff history separate |
| Direct-session filtering is applied inconsistently across SQL paths | Summary and future history endpoints drift in scope | Centralize and reuse the existing direct-session predicate pattern |
| Client starts using billing data for live context UI | UI becomes less responsive or semantically wrong | Keep `tokens_updated` for live display and use ledger/history only for completed turns |

## Phase 1: Re-baseline Current Semantics In Code And Tests
Goal: Lock the current design assumptions into tests before changing accounting behavior.
Why this phase first: We already have a partially-refactored system, and we need guardrails that reflect the current architecture before altering provider logic.
Files:
- `orbitdock-server/crates/connector-core/src/transition.rs` - add/adjust transition tests around `ContextTurn`, `MixedLegacy`, and completed-turn persistence.
- `orbitdock-server/crates/server/src/infrastructure/persistence/usage.rs` - add normalization tests that encode direct-session accounting expectations.
- `OrbitDockNative/OrbitDockTests/Server/Sessions/ServerTokenUsageSemanticsTests.swift` - preserve client-side semantic expectations for live display decoding.

Changes:
- [ ] Add a server test proving Codex `ContextTurn` live updates do not yet produce correct completed-turn accounting.
- [ ] Add a server test proving Claude `MixedLegacy` completed-turn accounting still works as expected.
- [ ] Add a test proving turns without diffs still persist usage rows, so we do not regress already-completed work.
- [ ] Document in-test language that live snapshot semantics and authoritative turn accounting are intentionally different.

Done when:
- [ ] The failing/coverage tests identify the remaining Codex correctness gap without reintroducing outdated assumptions from the April 4 plan.
- [ ] Tests clearly encode what is already solved versus what still needs implementation.

## Phase 2: Fix Provider-Specific Completed-Turn Accounting
Goal: Make completed-turn usage correct for direct sessions across Claude and Codex.
Why this phase next: Summary accuracy and any future per-turn history API depend on writing correct turn facts first.
Files:
- `orbitdock-server/crates/connector-core/src/transition.rs` - stop relying on `MixedLegacy`-only accumulators as the only completed-turn accounting mechanism.
- `orbitdock-server/crates/connector-codex/src/event_mapping/runtime_signals.rs` - keep or refine live token mapping with clear separation from accounting needs.
- `orbitdock-server/crates/server/src/runtime/transcript_sync_policy.rs` - ensure transcript-driven usage updates remain live-display semantics only.
- `orbitdock-server/crates/server/src/infrastructure/persistence/usage.rs` - preserve normalized ledger-writing behavior once the right turn facts are provided.
- `orbitdock-server/crates/server/src/infrastructure/persistence/session_writes.rs` - continue writing completed-turn usage through the authoritative persistence path.

Changes:
- [ ] Introduce a provider-aware completed-turn accounting path for Codex direct sessions.
- [ ] Preserve `TokensUpdated` as a live snapshot path for current session/control-deck UI.
- [ ] Ensure Claude direct sessions continue to finalize accurate turn usage from accumulated `MixedLegacy` data.
- [ ] Add regression tests covering multi-turn Codex sessions and restart-safe completed-turn persistence.

Done when:
- [ ] Codex completed turns persist non-zero, provider-correct usage when the provider reports token activity.
- [ ] Claude completed-turn accounting still passes existing semantics/regression tests.
- [ ] The persistence layer receives correct turn facts without needing to infer provider behavior from sparse SQL later.

## Phase 3: Scope Summary API To Direct Sessions
Goal: Ensure the summary endpoint reports only the sessions we care about.
Why this phase next: Once turn facts are correct, summary scope becomes the next biggest source of user-visible mismatch.
Files:
- `orbitdock-server/crates/server/src/transport/http/server_meta.rs` - filter sessions and ledger rows to direct sessions only.
- `OrbitDockNative/OrbitDock/Services/Server/API/UsageClient.swift` - no contract change expected unless we add explicit scope params.
- `OrbitDockNative/OrbitDock/Services/UsageServiceRegistry.swift` - validate that merged runtime summaries still behave correctly under the narrowed scope.

Changes:
- [ ] Apply the existing direct-session predicate pattern to `load_usage_summary` session counting.
- [ ] Apply the same predicate to ledger-row and legacy-fallback row loading.
- [ ] Add summary tests covering direct vs non-direct sessions.
- [ ] Decide whether the endpoint should remain implicitly direct-scoped or expose an explicit query parameter for future expansion.

Done when:
- [ ] `/api/usage/summary` excludes passive/non-direct sessions.
- [ ] Summary tests prove direct-session scope across both ledger and legacy-fallback paths.
- [ ] Native summary UI continues to decode and render without contract regressions.

## Phase 4: Add A Dedicated Per-Turn Usage History API
Goal: Provide a usage-first HTTP surface for eventual conversation/session UI.
Why this phase next: Once correctness and summary scope are fixed, we can safely expose historical turn usage without teaching the client to reverse-engineer it from diffs.
Files:
- `orbitdock-server/crates/server/src/transport/http/router.rs` - add route for per-turn usage history.
- `orbitdock-server/crates/server/src/transport/http/sessions.rs` or a new focused usage transport file - implement the endpoint.
- `orbitdock-server/crates/protocol/src/types.rs` - add shared payload types if we want protocol-level reuse.
- `orbitdock-server/crates/server/src/infrastructure/persistence/session_reads/session_hydration.rs` - leave diff hydration focused on diffs; avoid overloading it with usage-history responsibilities.
- `OrbitDockNative/OrbitDock/Services/Server/API/ConversationClient.swift` or `UsageClient.swift` - add client fetcher for per-turn usage history.
- `OrbitDockNative/OrbitDock/Services/Server/Protocol/ServerSessionContracts.swift` - add payload decoding for turn-usage history rows.

Changes:
- [ ] Design a direct-session per-turn usage payload with turn id, turn seq, provider/model context, billable token facts, context-window facts, observed time, and snapshot kind.
- [ ] Implement an HTTP endpoint that pages/sorts completed-turn usage independently of diff history.
- [ ] Keep `turn_diffs` unchanged so review/diff UI does not take on usage-history responsibilities.
- [ ] Add API and client decoding tests.

Done when:
- [ ] We can fetch per-turn usage for a session even when some turns have no diffs.
- [ ] The endpoint is HTTP bootstrap/history only, with no heavy WS payload addition.
- [ ] The payload is sufficient for future conversation-view token UI without another server redesign.

## Files To Modify
| File | Planned change |
|---|---|
| `plans/direct-session-token-tracking-plan-2026-04-11.md` | Source-of-truth implementation plan; update status as work progresses |
| `orbitdock-server/crates/connector-core/src/transition.rs` | Separate live token snapshots from authoritative completed-turn accounting |
| `orbitdock-server/crates/connector-codex/src/event_mapping/runtime_signals.rs` | Keep Codex live snapshot mapping explicit and aligned with provider semantics |
| `orbitdock-server/crates/server/src/runtime/transcript_sync_policy.rs` | Preserve transcript usage as live-display sync, not billing truth |
| `orbitdock-server/crates/server/src/infrastructure/persistence/usage.rs` | Continue normalized ledger writes and add targeted regression tests |
| `orbitdock-server/crates/server/src/infrastructure/persistence/session_writes.rs` | Keep completed-turn persistence authoritative once correct turn facts are provided |
| `orbitdock-server/crates/server/src/transport/http/server_meta.rs` | Direct-session summary filtering and tests |
| `orbitdock-server/crates/server/src/transport/http/router.rs` | Route dedicated per-turn usage endpoint |
| `orbitdock-server/crates/server/src/transport/http/sessions.rs` or a new transport file | Implement per-turn usage HTTP API |
| `orbitdock-server/crates/server/src/infrastructure/persistence/session_reads/session_hydration.rs` | Keep diff hydration scoped correctly; avoid mixing in usage-history responsibilities |
| `orbitdock-server/crates/protocol/src/types.rs` | Shared per-turn usage payload types if needed |
| `OrbitDockNative/OrbitDock/Services/Server/API/UsageClient.swift` | Summary contract call path, plus optional per-turn usage fetches |
| `OrbitDockNative/OrbitDock/Services/Server/API/ConversationClient.swift` | Optional home for per-turn usage history fetch depending on surface ownership |
| `OrbitDockNative/OrbitDock/Services/Server/Protocol/ServerSessionContracts.swift` | Decode new per-turn usage payloads |
| `OrbitDockNative/OrbitDock/Services/UsageServiceRegistry.swift` | Validate summary behavior after direct-session scoping |
| `OrbitDockNative/OrbitDockTests/Server/Sessions/ServerTokenUsageSemanticsTests.swift` | Preserve live token semantic expectations |

## Implementation Order
1. Re-baseline tests around current semantics so the new work starts from the real codebase rather than the April 4 assumptions.
2. Fix completed-turn provider accounting on the server, because every downstream surface depends on correct turn facts.
3. Scope `/api/usage/summary` to direct sessions once ledger truth is correct.
4. Add the dedicated per-turn usage HTTP surface for future conversation/session UI.
5. Wire client decoding and keep this plan updated as tasks move from open to done.

## Verification
Build or test commands:
- `cargo test -p orbitdock-server`
- `cargo test -p orbitdock-server usage_summary`
- `cargo test -p orbitdock-server transition`
- `xcodebuild -project OrbitDockNative/OrbitDock/OrbitDock.xcodeproj -scheme OrbitDock -destination 'platform=macOS' test`

Checks:
- [ ] Codex direct-session turns persist correct completed-turn usage across multiple turns.
- [ ] Claude direct-session turns still persist correct completed-turn usage.
- [ ] Usage summary excludes passive/non-direct sessions.
- [ ] Per-turn usage history can be fetched for a session even when no diff exists for some turns.
- [ ] Native client decodes the updated contracts without semantic regressions for live token display.

## Open Questions
- [ ] For Codex direct sessions, should authoritative completed-turn accounting come from total-usage deltas captured at turn boundaries, or from a new provider-emitted finalized turn usage event if we add one?
- [ ] Should `/api/usage/summary` become implicitly direct-only now, or should we add an explicit `scope=direct` query parameter for future-proofing?
- [ ] Should per-turn usage history live under `UsageClient` or `ConversationClient` on the native side?

## Definition Of Done
- [ ] This plan file is the active source of truth and is updated as phases/tasks complete.
- [ ] Direct-session completed-turn accounting is correct for both Claude and Codex.
- [ ] Summary totals are direct-session scoped.
- [ ] A dedicated per-turn usage HTTP contract exists and is tested.
- [ ] Live token UI semantics remain correct and distinct from billing/accounting semantics.
- [ ] Server and native regression coverage is in place for the changed contracts.
