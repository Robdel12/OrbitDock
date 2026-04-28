# Rust API Test Coverage Audit

Status: completed overnight pass; follow-up gaps documented
Started: 2026-04-28
Source of truth: this plan

## Goal

Aggressively audit every Rust API-facing test against `testing-philosophy`, then improve the suite so it gives confidence in user-visible API behavior instead of accumulating implementation-detail debt.

The preferred API test shape is: exercise REST endpoints or the closest public server boundary, use real persistence/runtime layers where feasible, assert authoritative user-observable responses and durable state, and avoid mocking OrbitDock internals. Pure unit tests are still valuable when they cover deterministic domain rules that would be awkward or wasteful to prove through HTTP.

## Non-Negotiables

- Test like a user: REST endpoints and returned payloads are the highest-value API surface.
- Test integration where integration matters: runtime, actor, persistence, and transport wiring should be covered together when the bug risk crosses layers.
- Do not mock our own code to make a tangled design testable. Refactor toward pure logic or exercise a real boundary.
- Mock only true external boundaries: AI providers, OS/process boundaries, network services, time, randomness.
- No arbitrary sleeps or polling waits in tests. Wait on concrete events, channels, responses, or persisted state.
- Keep server truth on the server: tests should prove HTTP-authoritative reads/mutations reflect durable state and actor state consistently.
- Prefer focused deletion over keeping cruft. A low-signal test that only pins helper trivia should either move to a pure domain test with real value or disappear.
- If a test exposes a product/architecture bug, fix the implementation and keep the test at the highest useful level.

## Definition Of Done

- Every file in the API-facing inventory below has a completed audit note.
- Every endpoint family has intentional coverage: endpoint-level, domain-level, or explicitly deferred with rationale.
- Low-value tests are rewritten, moved down to pure unit tests, or deleted.
- Missing high-value workflows are covered through REST or the closest public server boundary.
- New or rewritten tests avoid internal mocks, sleeps, and implementation-call assertions.
- Relevant server behavior is verified with `make rust-test` or a narrower documented Rust test command when appropriate.
- This plan is updated after each worker batch and remains the source of truth.

## Coverage Rubric

For each test file, classify each test as one of:

- `Keep`: asserts a meaningful API/user outcome at the right level.
- `Rewrite`: checks the right behavior but at the wrong level, with brittle setup, internal coupling, or weak assertions.
- `Promote`: should move up to REST/API coverage because the integration matters.
- `Demote`: should move down to a pure unit/domain test because HTTP adds noise without confidence.
- `Delete`: low-signal cruft, duplicated coverage, or implementation-detail pinning.
- `Add`: missing endpoint/user workflow coverage.

Required audit questions:

- What user-visible or durable server behavior does this prove?
- Does it cross a real API/runtime/persistence seam that users depend on?
- Is it mocking/stubbing an internal boundary that should be real?
- Does it wait on concrete state instead of timing?
- Would this test catch the regression we actually fear?

## Exposed HTTP Surface Map

These router families are the API coverage target:

- Hooks: `POST /api/hook`
- Session reads: active, archive, summary, detail, conversation bootstrap, review, history, search, stats, usage turns, row content, mark read
- Session writes: create, send message, steer, shell command, rename, summary, config
- Lifecycle: resume, takeover, end, fork, fork to worktree, fork to existing worktree
- Controls and approvals: controls snapshot, stop active turn, compact, undo, rollback, stop target, rewind, approval decisions, question answers, permission responses
- Attachments and shell: image upload/read, shell exec, shell cancel
- Session support: subagent tools/messages, runtime, collaboration modes, skills, plugins, MCP, flags, instructions, permission rules
- Global approvals and review comments
- Server: meta, role, OpenAI key, workspace provider/config/test, update status/check/start/channel, primary claim
- Usage and model catalogs: usage summary/breakdown/overview/sessions/codex/claude, codex models, claude models
- Codex account/config/auth/preferences
- Filesystem/sync: git init, browse, recent projects, sync batch
- Worktrees: list, create, discover, remove
- Missions: mission CRUD, issues, retry/transition/blocked/complete/PR, worktrees, scaffold, settings, default template, orchestrator, dispatch, trigger, tracker keys, global keys/defaults

Initial observation: existing API-facing tests cover important slices, but many route families have no direct endpoint-level tests yet. The audit should decide whether each gap needs REST coverage now, lower-level coverage is already better, or the route is external/OS-heavy enough to document as deferred.

## API-Facing Test Inventory

| Status | Owner | File | Current tests | Initial classification target |
| --- | --- | --- | ---: | --- |
| completed | W1 | `orbitdock-server/crates/server/src/transport/http/sessions/tests.rs` | 15 | Promoted read coverage for detail, history, review, stats, usage turns, and mark-read persistence |
| completed | W2 | `orbitdock-server/crates/server/src/transport/http/session_actions_tests.rs` | 4 | Added user-facing validation coverage for rollback and shell command dispatch guards |
| completed | W2 | `orbitdock-server/crates/server/src/transport/http/session_lifecycle/create_tests.rs` | 2 | Added deterministic route-level create failure coverage for missing Claude runtime |
| completed | W2 | `orbitdock-server/crates/server/src/transport/http/session_lifecycle/resume_tests.rs` | 2 | Tightened resume assertions around runtime-ready and persisted fallback behavior |
| completed | W3 | `orbitdock-server/crates/server/src/transport/http/capabilities/tests.rs` | 11 | Added MCP fallback/auth, flag application, and instruction merge behavior at public route seams |
| completed | W4 | `orbitdock-server/crates/server/src/transport/http/server_meta/tests.rs` | 9 | Promoted usage summary/sessions behavior to handler calls and removed brittle fixture assumptions |
| completed | W4 | `orbitdock-server/crates/server/src/transport/http/server_info/tests.rs` | 5 | Added server meta, OpenAI key, role, primary claim, and workspace provider endpoint coverage |
| completed | W4 | `orbitdock-server/crates/server/src/transport/http/update_tests.rs` | 3 | Added update status/channel route coverage and fixed handler state scoping |
| completed | W5 | `orbitdock-server/crates/server/src/transport/http/mission_control/tests.rs` | 1 | Added mission create/update/delete workflow and invalid-provider no-persist coverage |
| completed | W5 | `orbitdock-server/crates/server/src/transport/http/review_comments/tests.rs` | 2 | Strengthened create/update/delete workflow to assert authoritative payloads and durable state |
| completed | W5 | `orbitdock-server/crates/server/src/transport/http/sync_tests.rs` | 2 | Added missing bearer-auth rejection coverage |
| completed | W6 | `orbitdock-server/crates/server/src/transport/shell_streaming_tests.rs` | 4 | Tightened preview tail and multibyte truncation contracts |
| completed | W6 | `orbitdock-server/crates/server/src/transport/web_assets_tests.rs` | 2 | Kept as thin route fallback guards; no change needed |
| completed | W6 | `orbitdock-server/crates/cli/src/client/rest/tests.rs` | 1 | Kept current handshake coverage; validated through CLI lib suite |
| completed | W6 | `orbitdock-server/crates/cli/src/client/config/tests.rs` | 1 | Added wildcard host normalization coverage for user-visible CLI config |
| completed | W6 | `orbitdock-server/crates/server/src/app/app_tests.rs` | 2 | Added invalid persisted workspace-provider policy coverage |

## Near-API Runtime Support Inventory

These files are not REST tests, but they protect API-visible behavior. Audit after endpoint files, or in parallel when a worker owns the corresponding endpoint family.

| Status | Owner | File | Current tests | Why it matters to API confidence |
| --- | --- | --- | ---: | --- |
| completed | W7 | `orbitdock-server/crates/server/src/runtime/session_actor_tests.rs` | 11 | Tightened actor sequencing, replay, and persistence assertions for API-visible snapshots |
| completed | W7 | `orbitdock-server/crates/server/src/runtime/session_command_handler_tests.rs` | 13 | Tightened connector-event to snapshot/delta behavior without adding internal mocks |
| completed | W7 | `orbitdock-server/crates/server/src/runtime/session_broadcasts_tests.rs` | 3 | Clarified invalidation semantics used by REST/WS reconciliation |
| completed | W7 | `orbitdock-server/crates/server/src/runtime/session_row_history_tests.rs` | 3 | Tightened hydration and sequence merge behavior |
| completed | W8 | `orbitdock-server/crates/server/src/runtime/session_mutations_tests.rs` | 10 | Audited as valuable runtime support; no endpoint-forcing needed in this pass |
| completed | W8 | `orbitdock-server/crates/server/src/runtime/message_dispatch_tests.rs` | 6 | Audited as valuable runtime support for write routes; no change needed |
| completed | W8 | `orbitdock-server/crates/server/src/runtime/session_creation_tests.rs` | 7 | Removed arbitrary sleep in favor of concrete scheduler yielding |
| completed | W8 | `orbitdock-server/crates/server/src/runtime/session_resume_tests.rs` | 2 | Audited as pure lifecycle selection coverage; no change needed |
| completed | W8 | `orbitdock-server/crates/server/src/runtime/session_takeover_tests.rs` | 1 | Audited as focused takeover config behavior; no change needed |
| completed | W8 | `orbitdock-server/crates/server/src/runtime/session_lifecycle_policy_tests.rs` | 2 | Audited as pure takeover planning coverage; no change needed |
| completed | W9 | `orbitdock-server/crates/server/src/runtime/session_queries_tests.rs` | 3 | Audited as projection support for detail/light snapshots |
| completed | W9 | `orbitdock-server/crates/server/src/runtime/session_registry/tests.rs` | 7 | Added dashboard cache refresh regression coverage |
| completed | W9 | `orbitdock-server/crates/server/src/runtime/session_registry/connection_state_tests.rs` | 4 | Reworked as public seam tests for primary/orchestrator state |
| completed | W9 | `orbitdock-server/crates/server/src/runtime/session_registry/recent_projects_tests.rs` | 2 | Reworked recent-project behavior around real persisted rows |
| completed | W9 | `orbitdock-server/crates/server/src/runtime/dashboard_tests.rs` | 1 | Deleted low-signal private helper test and moved value into registry coverage |
| completed | W10 | `orbitdock-server/crates/server/src/runtime/mission_orchestrator_tests.rs` | 9 | Audited as mission runtime support; no change needed |
| completed | W10 | `orbitdock-server/crates/server/src/runtime/mission_reconciliation_tests.rs` | 12 | Replaced wall-clock now usage with deterministic timestamps and boundary coverage |
| completed | W10 | `orbitdock-server/crates/server/src/runtime/workspace_dispatch/local_tests.rs` | 13 | Audited as local dispatch contract; no change needed |
| completed | W10 | `orbitdock-server/crates/server/src/runtime/workspace_dispatch/daytona_tests.rs` | 2 | Audited as remote launch-plan contract; no change needed |
| completed | W10 | `orbitdock-server/crates/server/src/runtime/worktree_creation_tests.rs` | 1 | Audited as worktree persistence behavior; no change needed |
| completed | W10 | `orbitdock-server/crates/server/src/runtime/session_fork_targets_tests.rs` | 4 | Audited as fork/worktree validation coverage; no change needed |
| completed | W10 | `orbitdock-server/crates/server/src/runtime/session_runtime_helpers_tests.rs` | 10 | Audited as direct-session helper contract; no change needed |
| completed | W10 | `orbitdock-server/crates/server/src/runtime/restored_sessions_tests.rs` | 3 | Added ended-session restore behavior |
| completed | W10 | `orbitdock-server/crates/server/src/runtime/conversation_policy_tests.rs` | 2 | Audited as pure conversation window behavior; no change needed |
| completed | W10 | `orbitdock-server/crates/server/src/runtime/approval_dispatch_tests.rs` | 2 | Audited as approval normalization support; route coverage still deferred below |
| completed | W10 | `orbitdock-server/crates/server/src/runtime/background/git_refresh_tests.rs` | 3 | Audited as git refresh support; no change needed |

## Initial High-Risk Coverage Gaps

These are suspected gaps before the worker audits. Workers should confirm, refine, or close them.

- `POST /api/hook` appears to rely on connector hook tests rather than direct HTTP route tests; decide whether route-level auth/body/error coverage is needed.
- Session write endpoints (`send message`, `steer`, `rename`, `summary`, `config`, `end`) need confirmation that HTTP responses are authoritative and persistence follows.
- Lifecycle fork/takeover/end route families look under-covered at REST level.
- Approval/question/permission response endpoints need route-level workflow coverage or a documented lower-level substitute.
- Image attachment upload/read and shell exec/cancel routes need endpoint-level coverage decisions.
- Permission rules endpoints appear under-covered at REST level.
- Mission Control has many routes but only one direct `transport/http/mission_control/tests.rs` test; likely the biggest API coverage gap.
- Worktree routes appear to rely mostly on runtime/domain tests; decide whether create/list/delete/discover need REST-level integration coverage.
- Codex auth/config endpoints appear under-covered in server HTTP tests; connector-level tests may not prove REST semantics.
- Server key endpoints (`openai`, tracker keys) need checks for redaction, clear/delete semantics, and persistence without exposing secrets.
- Filesystem browse/recent-projects/git-init route coverage needs a safety-focused audit because OS boundaries are real external boundaries.

## Parallel Worker Plan

Each worker should update findings in its final response using this format: files audited, tests to keep/rewrite/delete/add, implementation bugs found, edits made, commands run, remaining risk. Workers that edit code must stay inside their assigned files unless a small adjacent implementation fix is necessary, and they must not revert other work.

- W1 Fermat (`019dd2fe-e650-7a43-91cf-61e6b567b364`): Session read APIs: `transport/http/sessions/tests.rs` plus direct implementation only if needed.
- W2 Rawls (`019dd2fe-ea7e-7481-807c-f438b3f8cbcb`): Session write/lifecycle/action APIs: `session_actions_tests.rs`, `session_lifecycle/create_tests.rs`, `session_lifecycle/resume_tests.rs`, and nearby lifecycle/action implementations.
- W3 Newton (`019dd2fe-ed77-7821-a999-ac1748d018e0`): Runtime/support APIs: `capabilities/tests.rs`, permissions/MCP/plugins/skills/runtime route coverage.
- W4 Heisenberg (`019dd2fe-f0c2-7e43-b287-b9fcafc802cc`): Server metadata/config/update APIs: `server_meta/tests.rs`, `server_info/tests.rs`, `update_tests.rs`.
- W5 Erdos (`019dd2fe-f436-7213-9fbd-0ea9a91f478b`): Mission/review/sync APIs: `mission_control/tests.rs`, `review_comments/tests.rs`, `sync_tests.rs`.
- W6 Plato (`019dd2fe-f73e-76d2-b38c-e6c54f03783c`): Thin transport and CLI client tests: shell streaming, web assets, CLI REST/config, app config policy.
- W7 Ptolemy (`019dd2fe-faf4-7073-9365-b0ba8f5ac34c`): Actor/conversation/broadcast runtime support for API-visible realtime and persistence semantics.
- W8 Lagrange (`019dd2fe-fe21-7d20-b54d-54d1a8647296`): Session mutation/creation/resume/takeover runtime support for lifecycle and write APIs.
- W9 Dalton (`019dd2ff-0128-7e83-9727-af09f385102a`): Query/registry/dashboard runtime projections backing read APIs.
- W10 Feynman (`019dd2ff-0473-78f1-a514-25879f1c7639`): Mission/worktree/runtime helpers and background support backing mission/worktree APIs.

## Coordinator Route Scan

This scan is heuristic: it checks whether route tokens appear in API-facing test files. A route listed here is not automatically untested, but it deserves explicit worker confirmation because no current endpoint-facing test obviously names it.

- `GET /api/sessions/{session_id}/detail`
- `POST /api/sessions/{session_id}/approvals/requests/{request_id}/decision`
- `POST /api/sessions/{session_id}/questions/requests/{request_id}/answer`
- `GET /api/sessions/{session_id}/subagents/{subagent_id}/messages`
- `POST /api/sessions/{session_id}/flags`
- `GET /api/approvals`
- `DELETE /api/approvals/{approval_id}`
- `GET/POST /api/server/openai-key`
- `GET/PUT /api/server/workspace-provider`
- `PUT /api/server/role`
- `GET /api/server/update-status`
- `POST /api/server/check-update`
- `POST /api/server/start-upgrade`
- `GET/PUT /api/server/update-channel`
- `POST /api/client/primary-claim`
- `GET /api/codex/account`
- `POST /api/codex/login/cancel`
- `POST /api/codex/logout`
- `GET/PUT /api/server/codex-preferences`
- `GET /api/fs/browse`
- `GET /api/fs/recent-projects`
- `GET/POST /api/worktrees`
- `POST /api/worktrees/discover`
- `DELETE /api/worktrees/{worktree_id}`
- `GET /api/missions/{mission_id}/worktrees`
- `POST /api/missions/{mission_id}/scaffold`
- `PUT /api/missions/{mission_id}/settings`
- `GET /api/missions/{mission_id}/default-template`
- `POST /api/missions/{mission_id}/start-orchestrator`
- `POST /api/missions/{mission_id}/trigger`
- `GET/PUT/DELETE /api/missions/{mission_id}/tracker-key`
- `POST /api/missions/{mission_id}/adopt-global-key`
- `GET/POST/DELETE /api/server/linear-key`
- `GET/POST/DELETE /api/server/github-key`
- `GET /api/server/tracker-keys`
- `GET/PUT /api/server/mission-defaults`

## Execution Phases

1. Inventory and plan: complete initial file/route map and spawn workers.
2. Worker audit pass: each worker classifies assigned tests and proposes/implements high-confidence cleanup or additions.
3. Integration pass: merge worker findings into this plan, resolve overlap, choose the highest-value missing API tests.
4. Implementation pass: add/rewrite/delete tests in focused batches, fixing implementation bugs when surfaced.
5. Verification pass: run targeted package tests first, then `make rust-test` when the Rust server suite is coherent.
6. Final cleanup: update plan statuses, summarize coverage changes, and document any consciously deferred gaps.

## Overnight Outcome

All 10 `gpt-5.4-mini` workers completed their assigned audits and edits. The coordinator integrated the work, fixed the remaining regressions, removed low-signal cruft, and verified the affected Rust packages.

Changed scope for this pass:

- 31 Rust/server-plan files changed under `orbitdock-server` plus this plan.
- 1,804 insertions and 440 deletions in the Rust/plan scope, excluding unrelated pre-existing Swift/doc worktree changes.
- Deleted `runtime/dashboard_tests.rs` after moving the meaningful dashboard cache behavior into public `SessionRegistry` coverage.
- Removed dead shell row-content test helpers that pinned implementation trivia instead of user-visible API behavior.
- Replaced the only touched arbitrary test sleep with scheduler yielding; remaining `tokio::time::sleep` hits in the scanned Rust paths are production watchdog/background loops, not tests.

High-value API coverage added or strengthened:

- Session reads now cover detail trimming/full payload toggles, conversation history pagination, review payloads, stats, usage turns, mark-read response semantics, and persisted unread reset.
- Session actions now reject zero-turn rollback and whitespace shell commands before connector dispatch.
- Create/resume lifecycle tests now cover user-visible runtime-start failure and persisted fallback behavior.
- Capabilities now cover MCP fallback, Codex MCP auth URL behavior, flag application, and Claude instruction merging.
- Server info/meta/update coverage now exercises handler-level responses for runtime metadata, OpenAI key writes, workspace provider config redaction, role/primary claim, cached update status, and persisted update channel.
- Mission Control now has a create/update/delete persistence round trip plus invalid-provider rejection without persisting junk.
- Review comments now assert authoritative create/update/delete payloads and durable state.
- Sync now rejects missing bearer auth before processing batches.
- Permission rules now have route-level add/remove/get coverage plus parsing/deduping coverage.
- Shell streaming now covers recent-tail retention and multibyte-safe preview truncation.

Implementation bugs fixed:

- Mission creation silently accepted unknown provider strings because `Provider::from_str` defaulted to Claude. The HTTP create path now rejects unknown providers with `400 invalid_provider` before enqueueing persistence.
- `GET /api/server/update-channel` read ambient/global config instead of the active server state's DB path. The handler now uses `SessionRegistry::db_path()` so tests and multi-data-dir runtime state resolve the same way.
- Mark-read test expectations were corrected to the actual API contract: the response reports the current unread count after reset, not the previous count.
- Mission test persistence flush acknowledgements were made non-hanging while still failing loudly if the flush fails.

Verification:

- `cargo fmt --all --manifest-path orbitdock-server/Cargo.toml`
- `env RUSTC_WRAPPER= cargo test --manifest-path orbitdock-server/Cargo.toml -p orbitdock-server transport::http::update::tests --lib -- --test-threads=1` → 5 passed
- `env RUSTC_WRAPPER= cargo test --manifest-path orbitdock-server/Cargo.toml -p orbitdock-server --lib -- --test-threads=1` → 584 passed
- `env RUSTC_WRAPPER= cargo test --manifest-path orbitdock-server/Cargo.toml -p orbitdock --lib` → 33 passed
- `env RUSTC_WRAPPER= cargo check --manifest-path orbitdock-server/Cargo.toml -p orbitdock-server` → passed

## Deferred Gaps

These are intentionally not swept under the rug. The overnight pass moved the suite materially forward, but the route map still has endpoint families that deserve a second wave.

- Mission issue routes still need direct REST coverage for retry, transition, blocked, complete, PR URL, worktrees, scaffold, settings, default template, orchestrator start, trigger, tracker keys, and server-level mission defaults/global keys.
- Worktree routes still rely mostly on domain/runtime tests; add REST coverage for list, create, discover, and remove when we can isolate filesystem/git boundaries cleanly.
- Approval/question/permission response workflows need route-level success-path tests around persisted approval state and connector dispatch.
- Image attachment upload/read and shell exec/cancel need endpoint-level coverage with real external-boundary seams.
- Fork/takeover/end success paths need more REST-level coverage beyond validation/domain support.
- MCP mutation routes such as refresh, toggle, clear auth, and set servers need route-level tests.
- Codex auth/config/account/logout/cancel/preference routes need REST semantics coverage.
- Update `set_update_channel` and `start_upgrade` still need stronger process/network-boundary harnessing; current coverage avoids spawning real upgrade work.
- Hook route coverage should be revisited for direct HTTP auth/body/error semantics even though connector hook behavior has lower-level coverage.
- Several HTTP tests still share the global migrated test DB; they should move toward per-test DB paths and state factories so the server API suite can run safely in parallel instead of relying on `--test-threads=1`.

## Activity Log

- 2026-04-28: Created initial inventory: 16 API-facing files / 66 tests, 26 near-API runtime files / 136 tests.
- 2026-04-28: Read HTTP router and identified route families plus initial suspected coverage gaps.
- 2026-04-28: Spawned 10 parallel `gpt-5.4-mini` workers and recorded ownership/agent IDs.
- 2026-04-28: Added coordinator route scan: 118 registered HTTP routes, 36 route patterns needing explicit coverage confirmation.
- 2026-04-28: Integrated all 10 worker outputs, promoted high-value REST coverage, deleted low-signal helper tests, and fixed surfaced implementation bugs.
- 2026-04-28: Verified formatting, full serial `orbitdock-server` lib tests, CLI lib tests, and server `cargo check`.
