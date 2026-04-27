# Server/API Refactor Plan

Date: 2026-04-26

Basis: [server-api-line-audit.md](server-api-line-audit.md) and [server-aggressive-deletion-plan.md](server-aggressive-deletion-plan.md)

Execution branch: `refactor/server-api-plan-execution`

Execution status:

- Current phase: `Phase 3 / first deletion slice`
- Current phase detail: `Slices 3A, 3B, 3C, 3D, 3E, 3F, 3G, 3H, 3I, 3J, 3K, 3L, 3M, 3N, 3O, 3P, 3R, 3S, 3T, 3U, 3V, 3X, 3Y, and 3Z are implemented and validated: HTTP conversation shims are gone, the WebSocket REST-only layer is gone, native/protocol dead leaves have been pruned, orphaned websocket utility payloads are gone, the dead CLI completions/pair leftovers are gone, the low-risk dead-code/test-support prune lane has continued landing cleanly, the persistence lane has dropped stale duplicate subagent writes plus unused mission/session-read helpers, the session domain has shed dead `SessionHandle`/`SessionCoreState` pass-throughs, the remaining test-only session/startup helpers are now compile-gated instead of shipping behind stale `dead_code` allowances, the persistence façade has dropped stale type/function re-exports that no live caller uses, the mixed helper slice removed an uncalled tunnel flow while test-gating or deleting dead retry/tool-PTY utilities, the mission-control read/tracker models have been pruned down to fields the runtime and HTTP surfaces actually consume, the remaining stale session mutators/accessors have been either deleted, test-gated, or relabeled as live, the parked conversation-semantics provider-event materialization path has been deleted instead of lingering behind comments and dead-code suppression, the lock-free `SessionSnapshot` shape has been tightened to fields production code actually reads, the post-migration `mixed_legacy` usage-accounting compatibility alias/checks have been removed from live server code so that legacy naming survives only in immutable migrations, the persistence read/restore path has shed redundant startup projections plus compatibility no-ops that no longer influence restored session state, startup recovery no longer carries a duplicate restore-select Claude shadow exclusion after the earlier startup cleanup already ends those direct-owned passive rows, restored sessions no longer carry stringified provider-mode transit fields that runtime code can derive directly from provider plus persisted control mode, the dashboard/session summary projection no longer selects dead raw integration-mode or tool-count columns that runtime code immediately recomputed or ignored, `session_reads.rs` no longer re-exports sibling-only helper glue that its child modules can import directly from the owning persistence submodules, the fake `SessionConfigPatch` concept is gone so the runtime/session domain now uses `SessionConfig` directly for both stored config and partial config updates, the remaining facet structs are imported from `facets.rs` directly instead of traveling through `session.rs` as a compatibility surface, and another read-only compatibility seam now trusts the migrated `control_mode` column directly in ownership lookups, light session hydration, dashboard/session projections, and usage summary filters instead of re-deriving direct/passive mode from legacy integration columns`
- Parent branch point: `c2da0f13`
- Wave 1 launched: yes
- Wave 2 launched: yes
- Phase 1 commit: `94ea8c58` (`♻️ Extract Rust tests into sibling modules`)

## Context

- This is one refactoring: reduce server/API complexity by extracting tests, deleting obsolete concepts, pruning protocols, and only then splitting remaining production modules.
- Baseline: `orbitdock-server` has 142,533 counted lines across 441 files.
- Baseline Rust: 122,855 lines across 370 `.rs` files.
- Focused server/API areas: 68,140 Rust lines across 231 files.
- Native `Services/Server`: 14,588 Swift lines across 64 files.

## Rust Test Convention Decision

Rust excludes normal `#[cfg(test)]` modules and test-only items from regular `cargo build` and release builds. So inline tests are not shipped in the server binary.

However, large inline test blocks are still a real cost:

- They make production files harder to read and review.
- They increase source parsing/navigation noise.
- They contribute to `cargo test` compile work.
- They encourage implementation-detail tests because private helpers are too easy to poke directly.

Decision: for this refactor, large tests should move into proper test files. This is acceptable Rust practice when a module is too large. Small pure-function unit tests can remain inline, but top hotspot files should not carry thousand-line test blocks.

Preferred patterns:

- For unit tests that need private module access, keep a test submodule but put it in a separate file with `#[cfg(test)] mod tests;` or an explicit `#[path = "..."] mod tests;`.
- For behavior tests that only need public APIs, move them to crate-level `tests/` integration tests.
- For tests that assert helper internals, delete or rewrite them around observable domain/runtime/persistence outcomes.

Important nuance: moving identical tests into separate files improves maintainability more than raw `cargo test` time. Compile-time wins come from deleting duplicate tests, converting implementation-detail tests into fewer outcome tests, and reducing dependencies pulled into test builds.

## Target Outcome

The target is not just smaller files. The target is fewer active concepts:

- Production files read like production code.
- Test files are organized by behavior and boundary.
- Dead compatibility branches are removed or explicitly documented as supported.
- HTTP owns reads/mutations; WebSocket owns light realtime deltas.
- Protocol modules represent current product contracts, not historical aggregates.
- Connector/event vocabularies shrink before the files are split.

## Guardrails

- Do not edit or delete existing migrations.
- Do not delete persistence restore/hydration support for databases we still support.
- Do not remove native-called REST endpoints without changing the native client in the same slice.
- Do not remove WebSocket events used by active UI flows without a replacement event or refetch path.
- Do not delete tests only because they are inline; delete tests when the feature is deleted or the behavior is covered better elsewhere.
- Keep server-authoritative state on the server.

## Parallel Worker Operating Model

Use aggressive parallel `gpt-5.4-mini` workers for this refactor. The work is naturally sliceable because the first pass is mostly mechanical test extraction with disjoint file ownership.

Rules for workers:

- Each worker owns a directory or explicit file set.
- Each worker must edit only its assigned files unless asked to coordinate.
- Each worker must not delete behavior during Phase 1 unless the test is plainly duplicated and the owner calls it out.
- Each worker must keep production behavior unchanged in Phase 1.
- Each worker must list changed files and any follow-up deletion candidates in its final note.
- The parent agent integrates, runs checks, resolves conflicts, and owns the final commit.
- Any worker lane that grows beyond about 25 files or more than one major hotspot should be split before launch.

Preferred worker model:

- Use `gpt-5.4-mini` for mechanical extraction and local cleanup.
- Keep architecture decisions, deletion calls, protocol pruning, and cross-layer changes with the parent agent or a stronger reviewer pass.
- Split workers by directory and write set, not by abstract theme, to avoid collisions.

Phase 1 extraction defaults:

- Default to sibling test files that preserve private-module access.
- Do not move tests to crate-level `tests/` integration tests in Phase 1 unless the test already uses only public APIs and the move is trivial.
- Do not create shared test helper modules across worker boundaries in Phase 1 unless the parent agent explicitly assigns that helper to one owner.
- Do not widen visibility just to make an integration-test move possible during Phase 1.
- Prefer `foo_tests.rs` or local sibling `tests.rs` patterns that keep the production module shape obvious.

Commit cadence:

- Phase 1 is its own commit: test structure only.
- Phase 2 is a planning/inventory commit if it produces durable docs or generated maps.
- Deletion phases should be committed by concept, not by directory, so each commit removes one coherent surface or compatibility path.

Parent integration cadence:

- Integrate Phase 1 in two waves, not one giant merge.
- Wave 1: hotspot crates and files where the conventions matter most.
- Wave 2: remaining crates after Wave 1 conventions are validated.
- After each wave, the parent agent runs checks, resolves naming/convention drift, and normalizes any inconsistent file layout before the next wave lands.

Worker final-note contract:

- List changed files.
- List tests moved versus intentionally left inline.
- Note any visibility or module-boundary pressure encountered.
- Call out duplicated setup builders worth centralizing later.
- List deletion candidates discovered while extracting tests.

## Phase 0: Launch Readiness

Objective: make sure the swarm starts from a stable contract.

Tasks:

- [x] Freeze the Phase 1 extraction conventions in this plan before spawning workers.
- [x] Confirm the parent agent owns all shared naming decisions and final file layout normalization.
- [x] Confirm workers will not create shared helpers or widen visibility without approval.
- [x] Confirm each worker has a disjoint write set.
- [x] Confirm the parent agent will integrate in waves and run validation between waves.

Done when:

- [x] The worker contract is stable.
- [x] File ownership is explicit.
- [x] Integration order is explicit.
- [x] There is no ambiguity about what counts as “test-structure only.”

## Phase 1: Extract All Rust Test Mass And Commit

Objective: make the entire Rust codebase easier to read and prepare for deletion without losing regression confidence.

Scope: all Rust crates under `orbitdock-server/crates/`, not just Claude or the connector hotspots.

Primary candidates:

- `orbitdock-server/crates/connector-core/src/transition.rs`: 4,412 lines, tests start around line 2857, 46 test cases.
- `orbitdock-server/crates/connector-codex/src/app_server.rs`: 3,090 lines, tests start around line 2634.
- `orbitdock-server/crates/connector-claude/src/lib.rs`: 3,560 lines, tests start around line 3157.
- `orbitdock-server/crates/server/src/runtime/session_command_handler.rs`: 1,456 lines, tests start around line 967.
- `orbitdock-server/crates/server/src/infrastructure/persistence/mission_control.rs`: 1,271 lines, tests start around line 495.
- `orbitdock-server/crates/server/src/infrastructure/persistence/usage.rs`: 1,301 lines, tests start around line 812.

Full sweep requirements:

- [ ] Find every inline `#[cfg(test)] mod tests` in `orbitdock-server/crates/**/*.rs`.
- [ ] Find every large standalone `tests.rs` or `*_tests.rs` module and decide whether to keep, split, rename, or move.
- [ ] Find test-only helper exports such as `#[cfg(test)] pub(crate)` and decide whether they should move into test support modules.
- [ ] Include `connector-core`, `connector-claude`, `connector-codex`, `protocol`, `server`, and `cli`.
- [ ] Leave tiny local tests inline only when they are genuinely clearer colocated than extracted.

Parallel workers:

| Worker | Model | Ownership | Mission |
| --- | --- | --- | --- |
| Worker A | `gpt-5.4-mini` | `connector-core` | Move transition tests out of the production reducer while preserving private-module access. |
| Worker B | `gpt-5.4-mini` | `connector-codex` | Extract app-server/config/rollout/session tests and identify duplicated setup helpers. |
| Worker C | `gpt-5.4-mini` | `connector-claude` | Extract Claude connector tests without touching connector behavior. |
| Worker D | `gpt-5.4-mini` | `protocol` | Extract or reorganize protocol tests across types, client/server messages, conversation contracts, and provider normalization. |
| Worker E | `gpt-5.4-mini` | `cli` | Extract CLI command/parser/output tests across the CLI crate. |
| Worker F1 | `gpt-5.4-mini` | server `domain` mission/worktree/conversation semantics | Extract domain tests outside the session core. |
| Worker F2A | `gpt-5.4-mini` | server `domain/sessions` | Extract domain session-state and restore tests while preserving private-module access. |
| Worker F2B | `gpt-5.4-mini` | server runtime session core | Extract session-command, actor, lifecycle, and registry-adjacent tests, which are the riskiest runtime hotspot outside persistence. |
| Worker F3 | `gpt-5.4-mini` | remaining server runtime | Extract runtime orchestration, dashboard, mission, workspace, and registry-adjacent tests outside the session core. |
| Worker G | `gpt-5.4-mini` | server `infrastructure/persistence` | Extract persistence tests and isolate restore/compatibility coverage. |
| Worker H | `gpt-5.4-mini` | server infrastructure outside persistence | Extract infrastructure tests for shell, terminal, GitHub, crypto, logging, migrations, and related helpers. |
| Worker I | `gpt-5.4-mini` | server `transport` | Extract HTTP/WebSocket tests and organize existing transport test modules. |
| Worker J | `gpt-5.4-mini` | server `admin`, `connectors`, `app`, and `support` | Extract remaining server tests outside domain/runtime/infrastructure/transport. |

Wave schedule:

- Wave 1: Workers A, B, C, D, E, G.
  Why: these files are the largest hotspots and establish the extraction conventions for connectors, protocol, CLI, and persistence.
- Wave 2: Workers F1, F2A, F2B, F3, H, I, J.
  Why: these are broader sweeps across the main server crate and should inherit the conventions proven in Wave 1.

Phase 1 file ownership:

Current sweep command found 149 Rust files with inline tests, test attributes, test modules, or test-only module declarations:

```bash
rg -l "#\\[cfg\\(test\\)\\]|#\\[test\\]|#\\[tokio::test\\]|mod tests" orbitdock-server/crates -g '*.rs' | sort
```

Wave 1 launch ledger:

| Worker | Agent | Status |
| --- | --- | --- |
| Worker A | `019dcc9c-b30d-7cd0-84bc-593975c3b019` (`Cicero`) | completed |
| Worker B | `019dcc9c-b69c-7b82-ad99-55a057d1866e` (`Socrates`) | completed |
| Worker C | `019dcc9c-b9fd-7ef2-8c9a-5ed0f73d3f1e` (`Plato`) | completed |
| Worker D | `019dcc9c-c191-7ea2-8da1-9791fe6b00d2` (`Darwin`) | completed |
| Worker E | `019dcc9c-c500-7362-a442-4340feaa994a` (`Nash`) | completed |
| Worker G | `019dcc9c-bd9c-7a61-b2fe-f2395b08338d` (`Euclid`) | completed |

Wave 1 integration notes:

- `connector-core` passed `cargo test -p orbitdock-connector-core --manifest-path orbitdock-server/Cargo.toml`.
- `connector-claude` passed `cargo test -p orbitdock-connector-claude --lib --manifest-path orbitdock-server/Cargo.toml`.
- `connector-codex` worker passed `cargo test -p orbitdock-connector-codex --lib --manifest-path orbitdock-server/Cargo.toml`.
- `cli` passed `cargo test -p orbitdock --lib --tests --manifest-path orbitdock-server/Cargo.toml`.
- `persistence` extraction landed cleanly in owned files; shared `persistence/tests.rs` intentionally remains for now.
- `protocol` passed `cargo test -p orbitdock-protocol --lib --manifest-path orbitdock-server/Cargo.toml` after a parent-requested normalization pass that removed duplicate root files and moved protocol tests to `*_tests.rs`.

Wave 2 launch ledger:

| Worker | Agent | Status |
| --- | --- | --- |
| Worker F1 | `019dcca9-a872-7fe2-94e3-30d29beb1211` (`Godel`) | completed |
| Worker F2A | `019dcca9-abf9-7c03-b7fd-691ec4b82586` (`Russell`) | completed |
| Worker F2B | `019dcca9-af7b-7602-bcac-326570fdc895` (`Epicurus`) | completed |
| Worker F3 | `019dcca9-b2d6-7101-997f-754ea2c3548a` (`Ramanujan`) | completed |
| Worker H | `019dcca9-b6cf-7db1-849c-058e57ae2191` (`Noether`) | completed |
| Worker I | `019dcca9-ba59-7a60-951c-e3430bc0a093` (`Maxwell`) | completed |
| Worker J | `019dcca9-bddb-78b3-8755-ccfd04d2eed0` (`Goodall`) | completed |

Parent validation notes after Wave 2:

- `cargo fmt --all` passed in `orbitdock-server/`.
- `make rust-check-workspace` passed.
- `cargo test -p orbitdock-protocol --lib --manifest-path orbitdock-server/Cargo.toml` passed.
- `cargo test -p orbitdock-connector-core --manifest-path orbitdock-server/Cargo.toml` passed.
- `cargo test -p orbitdock-connector-claude --lib --manifest-path orbitdock-server/Cargo.toml` passed.
- `cargo test -p orbitdock-connector-codex --lib --manifest-path orbitdock-server/Cargo.toml` passed.
- `cargo test -p orbitdock --lib --tests --manifest-path orbitdock-server/Cargo.toml` passed.
- `cargo test -p orbitdock-server --lib --manifest-path orbitdock-server/Cargo.toml -- --test-threads=1` passed.
- The default parallel `cargo test -p orbitdock-server --lib` still shows shared-test-state interference in older persistence tests; that is a pre-existing test-harness constraint surfaced during parent validation, not a production regression from Phase 1.

Phase 1 closeout:

- Phase 1 landed as commit `94ea8c58` (`♻️ Extract Rust tests into sibling modules`).
- The branch is clean after the Phase 1 commit.
- `orbitdock-server/crates` now contains 128 dedicated Rust test files.

### Worker A: connector-core

- `orbitdock-server/crates/connector-core/src/transition.rs`

### Worker B: connector-codex

- `orbitdock-server/crates/connector-codex/src/app_server.rs`
- `orbitdock-server/crates/connector-codex/src/auth.rs`
- `orbitdock-server/crates/connector-codex/src/config.rs`
- `orbitdock-server/crates/connector-codex/src/lib.rs`
- `orbitdock-server/crates/connector-codex/src/policy_bridge.rs`
- `orbitdock-server/crates/connector-codex/src/rollout_parser.rs`
- `orbitdock-server/crates/connector-codex/src/session_ops.rs`
- `orbitdock-server/crates/connector-codex/src/tests.rs`
- `orbitdock-server/crates/connector-codex/src/timeline.rs`
- `orbitdock-server/crates/connector-codex/src/workers.rs`

### Worker C: connector-claude

- `orbitdock-server/crates/connector-claude/src/lib.rs`
- `orbitdock-server/crates/connector-claude/src/session.rs`

### Worker D: protocol

- `orbitdock-server/crates/protocol/src/client.rs`
- `orbitdock-server/crates/protocol/src/conversation_contracts/rows.rs`
- `orbitdock-server/crates/protocol/src/conversation_contracts/tool_display.rs`
- `orbitdock-server/crates/protocol/src/diff_merge.rs`
- `orbitdock-server/crates/protocol/src/lib.rs`
- `orbitdock-server/crates/protocol/src/provider_normalization/claude.rs`
- `orbitdock-server/crates/protocol/src/provider_normalization/codex.rs`
- `orbitdock-server/crates/protocol/src/server.rs`
- `orbitdock-server/crates/protocol/src/types.rs`

### Worker E: cli

- `orbitdock-server/crates/cli/src/cli.rs`
- `orbitdock-server/crates/cli/src/client/config.rs`
- `orbitdock-server/crates/cli/src/client/rest.rs`
- `orbitdock-server/crates/cli/src/commands/session.rs`
- `orbitdock-server/crates/cli/src/commands/usage.rs`
- `orbitdock-server/crates/cli/src/dev_console.rs`
- `orbitdock-server/crates/cli/src/output/human.rs`
- `orbitdock-server/crates/cli/src/output/mod.rs`

### Worker F1: server domain mission/worktree/conversation semantics

- `orbitdock-server/crates/server/src/domain/codex_tools.rs`
- `orbitdock-server/crates/server/src/domain/conversation_semantics/codex.rs`
- `orbitdock-server/crates/server/src/domain/conversation_semantics/mod.rs`
- `orbitdock-server/crates/server/src/domain/conversation_semantics/shared.rs`
- `orbitdock-server/crates/server/src/domain/git/repo.rs`
- `orbitdock-server/crates/server/src/domain/mission_control/config.rs`
- `orbitdock-server/crates/server/src/domain/mission_control/eligibility.rs`
- `orbitdock-server/crates/server/src/domain/mission_control/executor.rs`
- `orbitdock-server/crates/server/src/domain/mission_control/prompt.rs`
- `orbitdock-server/crates/server/src/domain/mission_control/retry.rs`
- `orbitdock-server/crates/server/src/domain/mission_control/skills.rs`
- `orbitdock-server/crates/server/src/domain/mission_control/template.rs`
- `orbitdock-server/crates/server/src/domain/mission_control/tools.rs`
- `orbitdock-server/crates/server/src/domain/worktrees/include_copy.rs`
- `orbitdock-server/crates/server/src/domain/worktrees/service.rs`

### Worker F2A: server domain sessions

- `orbitdock-server/crates/server/src/domain/sessions/approval_state.rs`
- `orbitdock-server/crates/server/src/domain/sessions/conversation_state.rs`
- `orbitdock-server/crates/server/src/domain/sessions/diff_preview.rs`
- `orbitdock-server/crates/server/src/domain/sessions/restore.rs`
- `orbitdock-server/crates/server/src/domain/sessions/session.rs`
- `orbitdock-server/crates/server/src/domain/sessions/session_naming.rs`
- `orbitdock-server/crates/server/src/domain/sessions/snapshot.rs`
- `orbitdock-server/crates/server/src/domain/sessions/state.rs`

### Worker F2B: server runtime session core

- `orbitdock-server/crates/server/src/runtime/approval_dispatch.rs`
- `orbitdock-server/crates/server/src/runtime/conversation_policy.rs`
- `orbitdock-server/crates/server/src/runtime/message_dispatch.rs`
- `orbitdock-server/crates/server/src/runtime/restored_sessions.rs`
- `orbitdock-server/crates/server/src/runtime/session_actor.rs`
- `orbitdock-server/crates/server/src/runtime/session_broadcasts.rs`
- `orbitdock-server/crates/server/src/runtime/session_command_handler.rs`
- `orbitdock-server/crates/server/src/runtime/session_creation.rs`
- `orbitdock-server/crates/server/src/runtime/session_fork_targets.rs`
- `orbitdock-server/crates/server/src/runtime/session_lifecycle_policy.rs`
- `orbitdock-server/crates/server/src/runtime/session_mutations.rs`
- `orbitdock-server/crates/server/src/runtime/session_queries.rs`
- `orbitdock-server/crates/server/src/runtime/session_registry.rs`
- `orbitdock-server/crates/server/src/runtime/session_registry/connection_state.rs`
- `orbitdock-server/crates/server/src/runtime/session_registry/recent_projects.rs`
- `orbitdock-server/crates/server/src/runtime/session_resume.rs`
- `orbitdock-server/crates/server/src/runtime/session_runtime_helpers.rs`
- `orbitdock-server/crates/server/src/runtime/session_takeover.rs`

### Worker F3: remaining server runtime

- `orbitdock-server/crates/server/src/runtime/background/git_refresh.rs`
- `orbitdock-server/crates/server/src/runtime/dashboard.rs`
- `orbitdock-server/crates/server/src/runtime/mission_orchestrator.rs`
- `orbitdock-server/crates/server/src/runtime/mission_reconciliation.rs`
- `orbitdock-server/crates/server/src/runtime/workspace_dispatch/daytona.rs`
- `orbitdock-server/crates/server/src/runtime/workspace_dispatch/local.rs`
- `orbitdock-server/crates/server/src/runtime/worktree_creation.rs`

### Worker G: server persistence

- `orbitdock-server/crates/server/src/infrastructure/persistence/mission_control.rs`
- `orbitdock-server/crates/server/src/infrastructure/persistence/mod.rs`
- `orbitdock-server/crates/server/src/infrastructure/persistence/session_reads.rs`
- `orbitdock-server/crates/server/src/infrastructure/persistence/session_reads/ownership_reads.rs`
- `orbitdock-server/crates/server/src/infrastructure/persistence/session_reads/session_hydration.rs`
- `orbitdock-server/crates/server/src/infrastructure/persistence/session_reads/startup_recovery.rs`
- `orbitdock-server/crates/server/src/infrastructure/persistence/sync.rs`
- `orbitdock-server/crates/server/src/infrastructure/persistence/sync_tests.rs`
- `orbitdock-server/crates/server/src/infrastructure/persistence/sync_writer.rs`
- `orbitdock-server/crates/server/src/infrastructure/persistence/tests.rs`
- `orbitdock-server/crates/server/src/infrastructure/persistence/transcripts.rs`
- `orbitdock-server/crates/server/src/infrastructure/persistence/usage.rs`
- `orbitdock-server/crates/server/src/infrastructure/persistence/workspace_sync.rs`
- `orbitdock-server/crates/server/src/infrastructure/persistence/writer.rs`

### Worker H: server infrastructure outside persistence

- `orbitdock-server/crates/server/src/infrastructure/auth_tokens.rs`
- `orbitdock-server/crates/server/src/infrastructure/crypto.rs`
- `orbitdock-server/crates/server/src/infrastructure/daytona.rs`
- `orbitdock-server/crates/server/src/infrastructure/github/client.rs`
- `orbitdock-server/crates/server/src/infrastructure/github_releases/client.rs`
- `orbitdock-server/crates/server/src/infrastructure/github_releases/types.rs`
- `orbitdock-server/crates/server/src/infrastructure/housekeeping.rs`
- `orbitdock-server/crates/server/src/infrastructure/logging.rs`
- `orbitdock-server/crates/server/src/infrastructure/migration_runner.rs`
- `orbitdock-server/crates/server/src/infrastructure/paths.rs`
- `orbitdock-server/crates/server/src/infrastructure/shell.rs`
- `orbitdock-server/crates/server/src/infrastructure/terminal.rs`
- `orbitdock-server/crates/server/src/infrastructure/tool_pty.rs`
- `orbitdock-server/crates/server/src/infrastructure/usage_probe.rs`

### Worker I: server transport

- `orbitdock-server/crates/server/src/transport/http/capabilities/mod.rs`
- `orbitdock-server/crates/server/src/transport/http/capabilities/tests.rs`
- `orbitdock-server/crates/server/src/transport/http/mission_control/mod.rs`
- `orbitdock-server/crates/server/src/transport/http/mission_control/tests.rs`
- `orbitdock-server/crates/server/src/transport/http/mod.rs`
- `orbitdock-server/crates/server/src/transport/http/review_comments/mod.rs`
- `orbitdock-server/crates/server/src/transport/http/review_comments/tests.rs`
- `orbitdock-server/crates/server/src/transport/http/server_info/mod.rs`
- `orbitdock-server/crates/server/src/transport/http/server_info/tests.rs`
- `orbitdock-server/crates/server/src/transport/http/server_meta/mod.rs`
- `orbitdock-server/crates/server/src/transport/http/server_meta/tests.rs`
- `orbitdock-server/crates/server/src/transport/http/session_actions.rs`
- `orbitdock-server/crates/server/src/transport/http/session_lifecycle/create.rs`
- `orbitdock-server/crates/server/src/transport/http/session_lifecycle/resume.rs`
- `orbitdock-server/crates/server/src/transport/http/sessions/mod.rs`
- `orbitdock-server/crates/server/src/transport/http/sessions/row_content.rs`
- `orbitdock-server/crates/server/src/transport/http/sessions/tests.rs`
- `orbitdock-server/crates/server/src/transport/http/sync.rs`
- `orbitdock-server/crates/server/src/transport/http/update.rs`
- `orbitdock-server/crates/server/src/transport/shell_streaming.rs`
- `orbitdock-server/crates/server/src/transport/web_assets.rs`
- `orbitdock-server/crates/server/src/transport/websocket/mod.rs`

### Worker J: server admin, connectors, app, and support

- `orbitdock-server/crates/server/src/admin/bind_guard.rs`
- `orbitdock-server/crates/server/src/admin/doctor.rs`
- `orbitdock-server/crates/server/src/admin/ensure_path.rs`
- `orbitdock-server/crates/server/src/admin/hook_forward.rs`
- `orbitdock-server/crates/server/src/admin/install_hooks.rs`
- `orbitdock-server/crates/server/src/admin/install_service.rs`
- `orbitdock-server/crates/server/src/admin/pair.rs`
- `orbitdock-server/crates/server/src/admin/setup.rs`
- `orbitdock-server/crates/server/src/admin/tunnel.rs`
- `orbitdock-server/crates/server/src/app/mod.rs`
- `orbitdock-server/crates/server/src/connectors/claude_hooks/approval.rs`
- `orbitdock-server/crates/server/src/connectors/claude_hooks/handler.rs`
- `orbitdock-server/crates/server/src/connectors/codex_hooks/mod.rs`
- `orbitdock-server/crates/server/src/connectors/codex_session.rs`
- `orbitdock-server/crates/server/src/connectors/jsonl_tailer.rs`
- `orbitdock-server/crates/server/src/connectors/subagent_parser.rs`
- `orbitdock-server/crates/server/src/support/mod.rs`
- `orbitdock-server/crates/server/src/support/normalization.rs`
- `orbitdock-server/crates/server/src/support/session_modes.rs`
- `orbitdock-server/crates/server/src/support/session_paths.rs`
- `orbitdock-server/crates/server/src/support/snapshot_compaction.rs`

Tasks:

- [ ] Move large inline test modules into dedicated test files.
- [ ] Keep test modules behind `#[cfg(test)]`.
- [ ] Convert pure transition tests into focused state-machine test files.
- [ ] Move public-boundary behavior tests to integration tests where practical.
- [ ] Delete duplicated setup builders and centralize reusable test fixtures.
- [ ] Replace helper-internal tests with user-visible outcome tests when possible.
- [ ] Avoid cross-worker shared helpers during Phase 1 unless parent-owned.
- [ ] Keep module visibility unchanged unless a parent-approved exception is required.
- [ ] Normalize naming conventions after Wave 1 before Wave 2 begins.

Parent integration checklist:

- [x] Review every worker patch for write-set violations before integrating.
- [x] Integrate Wave 1 first and normalize naming/layout drift.
- [x] Run validation after Wave 1 before launching or integrating Wave 2.
- [x] Integrate Wave 2 only after Wave 1 conventions are stable.
- [x] Run whole-workspace validation before creating the Phase 1 commit.

Done when:

- [x] All Rust crates have been swept for inline and oversized test modules.
- [x] The top hotspot files expose production structure without thousand-line test tails.
- [x] Phase 1 changes are behavior-preserving.
- [x] `make rust-check` passes.
- [x] Targeted Rust tests for touched crates/modules pass.
- [x] The Phase 1 test-structure-only commit is created before deletion work starts.

## Phase 1.5: Regroup And Recut The Deletion Plan

Objective: pause after the test refactor, absorb what we learned, and update the next-phase plan before deleting aggressively.

This is a deliberate checkpoint. Once the tests are out of the way, production files should be much easier to scan, and the worker notes should surface duplicated helpers, stale coverage, and suspicious compatibility branches.

Tasks:

- [x] Rerun the line-count audit after the Phase 1 commit.
- [x] Compare top hotspots against the baseline in [server-api-line-audit.md](server-api-line-audit.md).
- [ ] Review every worker’s follow-up deletion candidates.
- [x] Update this plan with the highest-confidence deletion targets.
- [x] Split deletion targets into `safe mechanical`, `needs product decision`, and `needs migration/restore decision`.
- [x] Choose the next parallel-worker breakdown based on the refreshed production-only shape.

Post-Phase-1 evidence:

- Post-Phase-1 Rust totals from [server-api-line-audit.md](server-api-line-audit.md): `122,802` Rust lines across `489` files under `orbitdock-server/crates`.
- Production-only Rust now measures `97,663` lines across `361` non-test `.rs` files, with `128` dedicated test files carrying extracted coverage.
- Production-only server crate code now measures `64,817` lines, which means the next hotspot list is finally describing real production complexity rather than production-plus-test mass.
- Largest remaining production-only hotspots are still `connector-claude/src/lib.rs` (`3,157`), `connector-core/src/transition.rs` (`2,858`), `protocol/src/types.rs` (`2,643`), `connector-codex/src/app_server.rs` (`2,635`), and `cli/src/commands/session.rs` (`2,198`).

Highest-confidence deletion buckets:

- `safe mechanical`
  - Sweep `#[allow(dead_code)]` and now-unused private helpers in connector, runtime, and persistence areas one at a time behind compile checks.
  - Remove WebSocket reject-only or REST-only policy glue once the route inventory confirms there is no active mutation client depending on it.
  - Delete test-only boundary-piercing helpers that survived Phase 1 once their callers are rewritten around domain/runtime/persistence outcomes.
  - Delete DTOs and protocol fields that are neither sent by the server nor decoded by native once the cross-reference pass proves they are dead.
- `needs product decision`
  - CLI bulk session surface in `orbitdock-server/crates/cli/src/commands/session.rs` and adjacent CLI entry wiring.
  - Admin/install/service flows under `orbitdock-server/crates/server/src/admin/`.
  - Mission Control server surface across domain/runtime/http/persistence.
  - Daytona workspace paths and related infrastructure.
  - Linear or GitHub-release-adjacent operational surfaces that may no longer be strategic.
- `needs migration/restore decision`
  - `mixed_legacy` usage repair and related accounting compatibility in `infrastructure/persistence/usage.rs`.
  - Claude passive shadow-session preservation and cleanup branches.
  - Startup restore and session hydration compatibility branches in `session_reads/startup_recovery.rs`, `session_reads/session_hydration.rs`, and adjacent persistence restore paths.

Done when:

- [x] The deletion queue is updated from fresh post-test-refactor evidence.
- [x] The next phase has explicit worker ownership and commit boundaries.
- [x] We have agreed which surfaces are fair game for aggressive deletion.

## Phase 2: Inventory Active Surface

Objective: know what can be deleted before cutting.

This phase starts only after the Phase 1 commit and the Phase 1.5 regroup.

Parallel workers:

| Worker | Model | Ownership | Mission |
| --- | --- | --- | --- |
| Worker A | `gpt-5.4-mini` | `orbitdock-server/crates/server/src/transport/http/` | Produce an HTTP route inventory, map each route to runtime/domain ownership, and tag it `active`, `compatibility`, `freeze`, or `delete-candidate`. |
| Worker B | `gpt-5.4-mini` | `orbitdock-server/crates/server/src/transport/websocket/` | Produce a WebSocket message and handler inventory, identify REST overlap, and call out reject-only or policy-only surfaces. |
| Worker C | `gpt-5.4-mini` | `OrbitDockNative/OrbitDock/Services/Server/API/` and `OrbitDockNative/OrbitDock/Services/Server/Protocol/` | Map native HTTP calls, WebSocket decode paths, and protocol fields the app actually consumes. |
| Worker D | `gpt-5.4-mini` | `orbitdock-server/crates/cli/src/commands/`, `cli/src/cli.rs`, `cli/src/dev_console.rs` | Inventory CLI surfaces and tag commands as `active`, `freeze`, or `delete-candidate`. |
| Worker E | `gpt-5.4-mini` | `orbitdock-server/crates/protocol/src/` | Cross-reference protocol structs, enums, and fields against server producers and native consumers. |
| Worker F | `gpt-5.4-mini` | `orbitdock-server/crates/connector-*` and `orbitdock-server/crates/server/src/connectors/` | Map emitted connector events, control paths, and old connector-specific compatibility branches. |
| Worker G | `gpt-5.4-mini` | `orbitdock-server/crates/server/src/infrastructure/persistence/` | Inventory restore, hydration, usage-repair, shadow-session, and compatibility branches that gate aggressive deletion. |
| Worker H | `gpt-5.4-mini` | `orbitdock-server/crates/server/src/admin/`, `domain/mission_control/`, `runtime/mission_*`, `runtime/workspace_*`, `infrastructure/daytona.rs` | Inventory admin, mission, and workspace surfaces and tag them `keep`, `freeze`, `delete-candidate`, or `needs product call`. |

Phase 2 worker output contract:

- Every worker returns a file/path inventory with one status per route, message, command, type, or compatibility path: `active`, `compatibility`, `freeze`, `delete-candidate`, or `needs product call`.
- Every worker must include concrete evidence: source file paths, entrypoints, and caller/callee references.
- Every worker must list the top 5 highest-confidence deletion candidates in its lane.
- Every worker must call out blockers separately when deletion would require native client changes, persistence compatibility decisions, or product sign-off.
- Workers are read-only in Phase 2 unless the parent agent asks for a follow-up patch.

Phase 2 commit boundaries:

- Inventory and planning updates can land as a docs-only commit if they materially improve the deletion map.
- The first actual deletion commit should remove one coherent surface end-to-end rather than mixing unrelated small cuts.

Phase 2 launch ledger:

| Worker | Agent | Status |
| --- | --- | --- |
| Worker A | `019dccc5-d6bd-7032-b894-b883c5f1b4f0` (`Tesla`) | completed |
| Worker B | `019dccc5-da67-7d71-8323-7f9cb29a2c6a` (`Faraday`) | completed |
| Worker C | `019dccc5-ddc0-7811-9a5a-0461524fb7c9` (`James`) | completed |
| Worker D | `019dccc5-e195-7791-adb3-269536f083aa` (`Franklin`) | completed |
| Worker E | `019dccc5-e612-72c1-82d4-5bb7b30201d4` (`Bohr`) | completed |
| Worker F | `019dccc5-e942-7691-ac02-fefb5feaf7cc` (`Bernoulli`) | completed |
| Worker G | `019dccc5-ecce-7080-8169-9715fabd0a1f` (`Euler`) | completed |
| Worker H | `019dccc5-f052-7943-948b-a2c7a860c5af` (`Locke`) | completed |

Phase 2 findings summary:

- HTTP is mostly live, but the `/api/sessions/{session_id}/conversation/{interrupt,compact,undo,rollback,stop,rewind}` family is a compatibility shim over `/controls/*`.
- Native already routes the live control-deck and session actions through `SessionControlsClient`; the matching `ConversationClient` control methods are unused leftovers.
- WebSocket still carries a large `rest_only_policy.rs` redirect/reject layer plus a few reject-only handlers. That is a strong follow-up deletion slice after we finish the HTTP shim removal.
- CLI has real delete candidates in hidden bridge commands and the dev console, but many session/worktree/mission flows are still compatibility mirrors of active server surfaces.
- Protocol has a few clear dead leaves such as `ConversationDisplayMode`, `ToolPayloadReference`, native-unused typed payloads, and compatibility-only websocket result cases, but those should be pruned with cross-layer confirmation.
- Persistence and connector complexity are not good first-cut deletion targets. `mixed_legacy`, shadow-session cleanup, startup recovery, and direct/passive ownership paths are migration/restore decisions, not free simplifications.

First deletion slice:

- Remove the legacy HTTP conversation control shim family:
  - `POST /api/sessions/{session_id}/conversation/interrupt`
  - `POST /api/sessions/{session_id}/conversation/compact`
  - `POST /api/sessions/{session_id}/conversation/undo`
  - `POST /api/sessions/{session_id}/conversation/rollback`
  - `POST /api/sessions/{session_id}/conversation/stop`
  - `POST /api/sessions/{session_id}/conversation/rewind`
- Remove the matching unused native leftovers in `OrbitDockNative/OrbitDock/Services/Server/API/ConversationClient.swift`.
- Update server docs that still advertise the shim routes and mark them as compatibility surfaces.
- Leave the canonical `/controls/*` HTTP routes in place.
- Leave WebSocket compatibility mutations alone in this slice because the CLI still uses them.

Tasks:

- [x] Inventory HTTP routes from `orbitdock-server/crates/server/src/transport/http/router.rs` and subrouters.
- [x] Inventory WebSocket messages from `orbitdock-server/crates/server/src/transport/websocket/router.rs` and handlers.
- [x] Inventory native API calls from `OrbitDockNative/OrbitDock/Services/Server/API/`.
- [x] Inventory CLI commands from `orbitdock-server/crates/cli/src/commands/`.
- [x] Cross-reference protocol structs from `orbitdock-server/crates/protocol/src/types.rs`, `client.rs`, and `server.rs`.

Done when each route/message/command/type/compatibility path is tagged as `active`, `compatibility`, `freeze`, `delete-candidate`, or `needs product call`.

Status: complete. The inventory is complete enough to start deletion by coherent surface rather than by file.

## Phase 3: Delete Dead Compatibility Paths

Objective: remove old behavior before reorganizing current behavior.

This phase should use parallel workers for research and patch prep, but deletion commits are integrated centrally by concept.

Current slice status:

- `Slice 3A`: complete. Removed the legacy HTTP conversation control shim family under `/api/sessions/{session_id}/conversation/*` for interrupt, compact, undo, rollback, stop, and rewind.
- Native cleanup in the same slice: complete. Removed the unused `ConversationClient` compatibility methods that still targeted those deleted routes.
- Docs cleanup in the same slice: complete. `API.md` no longer advertises the shim endpoints, and `SPEC.md` now states that those compatibility routes were removed.
- `Slice 3B`: complete. Removed the WebSocket `rest_only` redirect/reject layer, the matching REST-only `ClientMessage` variants, and the reject-only approval/config/Claude-hook branches that only existed to point callers back to HTTP.
- `Slice 3C`: complete. Removed definition-only protocol and native leaves: `ConversationDisplayMode`, `ToolPayloadReference`, `SessionComposerSnapshot`, `ServerSessionComposerSnapshotPayload`, `ServerSessionRuntimeSnapshot`, `SessionRuntimeClient.fetchRuntimeSnapshot(_:)`, and the unused native Codex-preferences request/response methods.
- `Slice 3D`: complete. Inventory confirmed the hidden bridge commands `hook-forward`, `managed-session-start`, and `mcp-mission-tools` are still live, and the dev console is still the supported interactive `make rust-run*` UX, so they stayed. The actual dead CLI leftovers inside that lane are now gone instead: the ignored `pair --no-qr` flag, the non-dispatched `completions` command, the unused completion-generator helpers, the stale `clap_complete` dependency entries, and the matching README mention.
- `Slice 3E`: complete. Removed the orphaned WebSocket utility payloads `DirectoryListing`, `RecentProjectsList`, `CodexUsageResult`, `ClaudeUsageResult`, and `OpenAiKeyStatus` from the server protocol, protocol roundtrip tests, CLI event labeling, and native WebSocket mirrors after confirming they had no live server producers. Shared HTTP payload structs remain in place, and `SteerOutcome` was intentionally left alone because the runtime still emits it.
- `Slice 3F`: complete. The low-risk `dead_code` prune lane now includes the unused `reset_data_dir()` helper, the unused `get_session_list_items()` registry helper, the unused `session_id` field from `ConnectorCleanupGuard`, stale `#[allow(dead_code)]` suppressions from the test extraction pass, the unreferenced `SessionActorHandle` convenience methods `try_send`, `snapshot_swap`, and `command_tx`, the dead `IncrementToolCount` session command, the test-only `execute_with_stream` shell wrapper that was replaced by testing the real `ShellService` surface directly, deleted unused HTTP/WebSocket test helper functions, removed stale dead-code suppressions in shared test support, removed the stale dead-code suppression on `resolve_claude_thread`, compile-gated `SetWorkStatus` to tests instead of shipping it in production, deleted the now-orphaned WebSocket test-support module, and removed the now-unused `SessionRegistry::new` test constructor it depended on.
- `Slice 3G`: complete. Removed the stale duplicate `persist_subagent_upsert` still parked in `infrastructure/persistence/mod.rs` after the real implementation moved to `subagent_writes.rs`, deleted the orphaned `load_all_active_mission_issues` mission-control reader, and pruned the unused test-only `*_from_db_path` session-read helpers that had no callers left (`load_session_lifecycle_state_from_db_path`, `load_session_by_id_from_db_path`, `load_direct_claude_owner_by_sdk_session_id_from_db_path`, and `load_direct_codex_owner_by_thread_id_from_db_path`).
- `Slice 3H`: complete. Removed the uncalled `SessionHandle` pass-through helpers `subagents`, `first_prompt`, `transcript_path`, `update_tokens`, `update_diff`, and `update_plan`, then deleted the matching dead `SessionCoreState` helpers they were forwarding into. The remaining session mutators that are still only used by test modules (`set_subagents`, `set_pending_attention`, and `set_first_prompt`) are now correctly compile-gated behind `#[cfg(test)]` instead of shipping in production.
- `Slice 3I`: complete. Tightened the remaining test-only session helpers by compile-gating `config`, `newest_synced_row_id`, `set_newest_synced_row_id`, and `set_last_tool` in both `SessionHandle` and `SessionCoreState`, removed the stale `#[allow(dead_code)]` marker from the still-live `has_user_row_with_content` dedup helper, and dropped stale dead-code suppressions from the test-only startup recovery helpers that are already exercised by persistence tests.
- `Slice 3J`: complete. Trimmed the persistence façade by dropping the stale `load_missions`, `extract_summary_from_transcript`, `TranscriptCapabilities`, and `WorktreeRow` re-exports, then removed the now-unnecessary `#[allow(unused_imports)]` shields around those re-export blocks once compile-check confirmed which exports were genuinely unused.
- `Slice 3K`: complete. Removed the uncalled `admin::tunnel::start_tunnel_and_extract_url` flow, compile-gated the `mission_control::retry` module because it only serves test coverage today, dropped the stale dead-code marker from its `compute_delay` helper, and tightened `ToolPtyService` so `get_replay_buffer`, `status`, and `exists` only compile for tests while the dead `get_session_id`, `subscriber_count`, and `cleanup_if` helpers are gone entirely. The stale dead-code marker on the stored `session_id` field is gone too because `subscribe()` still uses it for session isolation.
- `Slice 3L`: complete. Pruned unread fields out of the mission-control data models instead of just suppressing warnings: `TrackerIssue.blocked_by` and `BlockerRef` are gone, `MissionRow` no longer carries `last_parsed_at`, `created_at`, `updated_at`, or `tracker_api_key`, and `MissionIssueRow` no longer carries `id`, `mission_id`, `retry_due_at`, or `updated_at`. The Linear/GitHub tracker mappers, manual mission-orchestrator issue synthesis, and persistence row projections were all tightened to the slimmer shapes, and the persistence tests were updated to assert on the surviving identity fields.
- `Slice 3M`: complete. Cleaned up the last obviously stale session mutators/accessors outside the intentionally parked future work: `set_worktree_info` lost its stale dead-code label because production hook materialization already uses it, `set_status` and `set_last_activity_at` are now test-only APIs behind `#[cfg(test)]`, and the never-called `repository_root`, `is_worktree`, `worktree_id`, and `set_started_at` session/state helpers were deleted outright.
- `Slice 3N`: complete. Deleted the parked conversation-semantics provider-event materialization flow instead of keeping it as commented future work: `domain/conversation_semantics::materialize_provider_event` is gone, Codex no longer advertises `"provider_event"` as a handled wrapper, and the provider-event-only helper cluster for worker/approval/question/context/system row materialization was removed with it.
- `Slice 3O`: complete. Used the now-clean dead-code search to tighten `SessionSnapshot` itself: the last blanket `#[allow(dead_code)]` is gone, snapshot-only baggage (`message_count`, `current_diff`, `terminal_session_id`, and `terminal_app`) has been removed from the lock-free snapshot shape, `SessionRestoreSnapshotInput.rows` was dropped once that count stopped feeding the snapshot, and the affected tests now assert on authoritative retained state instead of deleted snapshot convenience fields.
- `Slice 3P`: complete. Removed the runtime `mixed_legacy` usage-accounting alias and repair triggers from `infrastructure/persistence/usage.rs` after confirming that `V047` and `V048` already normalize that legacy name during migrations. The repair path still backfills missing ledger/session-state data and fixes stale timestamps, but live server logic no longer carries a post-migration compatibility name that supported databases should never expose.
- `Slice 3R`: complete. Trimmed stale persistence/session-read compatibility baggage without changing restored behavior: `resolve_custom_name_from_first_prompt` is gone because it was a no-op, the hydration path no longer selects ignored legacy integration-mode columns, startup recovery no longer carts around an unused `summary` or `codex_integration_mode` projection just to ignore them later, and `infer_codex_config_mode` now accepts only the single raw mode value it actually uses.
- `Slice 3S`: complete. Narrowed the Claude shadow cleanup lane to the only delete that proved safe without weakening the live race guard: `startup_recovery.rs` no longer re-checks the direct-owned passive Claude shadow exclusion in the restore `SELECT` after the earlier startup `UPDATE` has already ended those rows. The persistence-layer ownership guard and hook suppression paths stay in place because they still protect active runtime and workspace-sync replay ordering.
- `Slice 3T`: complete. Removed the remaining stringified integration-mode transit baggage from restored sessions. `RestoredSession` no longer carries `codex_integration_mode` or `claude_integration_mode`, the session read path no longer synthesizes those strings during hydration/startup recovery, and runtime restore now derives the provider-specific integration mode directly from `provider + control_mode`. The persistence tests were tightened to assert on the authoritative persisted `control_mode` instead of deleted compatibility strings.
- `Slice 3U`: complete. Removed dead reads from `runtime/session_queries.rs`: the dashboard/library projection no longer selects raw `codex_integration_mode`, raw `claude_integration_mode`, or persisted `tool_count` columns that `map_projection_row` was not actually using. Runtime still derives provider-specific integration modes from `provider + control_mode`, and the live dashboard tool count remains sourced from in-memory session state where it belongs.
- `Slice 3V`: complete. Flattened `infrastructure/persistence/session_reads.rs` by deleting the sibling-only forwarding re-exports for transcript/message/usage helpers. `session_hydration.rs` and `startup_recovery.rs` now import those helpers directly from their owning persistence submodules, so the read path no longer has an internal barrel layer that only obscures where the real implementations live.
- `Slice 3X`: complete. Deleted `SessionConfigPatch`, which was only a naming alias for `SessionConfig`. Session/domain/runtime callsites now use `SessionConfig` directly for partial config updates, so there is one fewer fake concept to keep around before the larger session-file breakup.
- `Slice 3Y`: complete. Deleted the `session.rs` facets re-export surface. Callers that need `SessionIdentity`, `SessionConfig`, `SessionDisplay`, `SessionEnvironment`, or `SessionTimestamps` now import them from `facets.rs` directly, leaving `session.rs` focused on the actual session handle/snapshot/restore types it owns.
- `Slice 3Z`: complete. Removed another chunk of `control_mode` compatibility fallback on the read side. Ownership lookups, `load_session_by_id`, dashboard/session summary projection, runtime ownership resolution, and usage summary filtering now read the migrated `control_mode` column directly instead of reconstructing direct/passive mode from `codex_integration_mode` or `claude_integration_mode`.

Next queued slices:

- `Slice 3Q`: review the remaining Claude direct/passive shadow-session preservation and cleanup branches, but treat the persistence guard and hook suppression paths as live unless we redesign the direct-ownership race. Current analysis says `preserve_direct_owned_claude_shadow` still protects real runtime and workspace-sync replay ordering.
- `Slice 3AA`: review the remaining write/startup-side `control_mode` compatibility fallbacks now that the read path has been tightened. Start with `startup_recovery.rs`, `runtime/session_registry/ownership.rs` callers that still depend on startup-populated ownership rows, and `infrastructure/persistence/mod.rs` only if we can prove the direct-owner write guard still has enough coverage without integration-column fallback.

Search targets:

- Claude direct/passive shadow-session preservation paths.
- Test-only helper exports in session read/restore modules.
- WebSocket handlers that exist only to reject or redirect REST-only mutations.
- `SessionHandle` pass-through methods that forward to `SessionCoreState` but are no longer called anywhere.
- `#[allow(unused_imports)]` re-exports in persistence that may have gone stale after the recent delete slices.

Tasks:

- [ ] Remove one `#[allow(dead_code)]` at a time and let `make rust-check` identify fallout.
- [x] Decide whether `mixed_legacy` usage repair is still supported. Delete if not.
- [ ] Decide whether old Claude passive shadow rows are still supported. Delete cleanup/preservation branches if not.
- [ ] Delete connector events no active provider emits.
- [ ] Delete protocol fields no active client reads and no server sends.

Done when compatibility code is either removed or explicitly documented as supported.

## Phase 4: Cut Whole Surfaces

Objective: get real simplification by deleting complete product or tooling surfaces, not nibbling helpers.

Decision candidates:

- CLI bulk session surface: `orbitdock-server/crates/cli/src/commands/session.rs` and `cli.rs`.
- Admin/install/service flows in `orbitdock-server/crates/server/src/admin/`.
- Mission Control server surface.
- Daytona workspace dispatch and infrastructure.
- Linear/GitHub release infrastructure.
- Legacy direct Codex runtime/session paths if app-server fully owns Codex sessions.

Tasks:

- [ ] Mark each candidate `keep`, `delete`, or `freeze`.
- [ ] For every `delete`, remove route, runtime command, persistence path, protocol type, native client, CLI command, docs, and tests together.
- [ ] For every `freeze`, stop adding new coverage except smoke tests.
- [ ] For every `keep`, name the active user workflow and owning layer.

Done when at least one whole obsolete surface is removed end-to-end.

## Phase 5: Protocol Pruning

Objective: make protocol reflect active contracts only.

Targets:

- `orbitdock-server/crates/protocol/src/types.rs`: 2,911 lines.
- `orbitdock-server/crates/protocol/src/client.rs`: 1,695 lines.
- `orbitdock-server/crates/protocol/src/server.rs`: 1,002 lines.
- Native mirrors in `OrbitDockNative/OrbitDock/Services/Server/Protocol/`.

Tasks:

- [ ] Delete unused types and fields before splitting modules.
- [ ] Remove WebSocket client-to-server variants that duplicate REST mutations.
- [ ] Group active protocol by surface after deletion: sessions, conversation, usage, permissions, capabilities, missions if kept.
- [ ] Update native protocol mirrors in the same slice.

Done when protocol modules contain current contracts and compile-time dead fields are gone.

## Phase 6: Connector Simplification

Objective: reduce provider-specific translation to the current runtime paths.

Targets:

- `orbitdock-server/crates/connector-claude/src/lib.rs`: 3,560 lines.
- `orbitdock-server/crates/connector-core/src/transition.rs`: 4,412 lines.
- `orbitdock-server/crates/connector-codex/src/app_server.rs`: 3,090 lines.
- `orbitdock-server/crates/server/src/connectors/codex_hooks/mod.rs`: 1,197 lines.
- `orbitdock-server/crates/server/src/connectors/codex_session.rs`: 964 lines.

Tasks:

- [ ] Confirm whether old direct Codex runtime/session paths are reachable.
- [ ] Delete obsolete control requests and message handlers.
- [ ] Delete transition inputs/effects no provider emits.
- [ ] Move approval preview/risk/diff rendering out of the reducer after unused preview types are gone.
- [ ] Split remaining connector files by responsibility only after deletion.

Done when provider connectors emit fewer event types and the core reducer handles fewer cases.

## Phase 7: Transport Cleanup

Objective: enforce the API transport contract.

Targets:

- `orbitdock-server/crates/server/src/transport/http/session_actions.rs`: 826 lines.
- `orbitdock-server/crates/server/src/transport/http/session_lifecycle/create.rs`: 489 lines.
- `orbitdock-server/crates/server/src/transport/websocket/handlers/`.
- `orbitdock-server/crates/server/src/transport/websocket/rest_only_policy.rs`.

Tasks:

- [ ] Delete WebSocket mutation handlers now covered by REST.
- [ ] Delete HTTP response fields duplicated by subscription snapshots unless needed for immediate mutation results.
- [ ] Delete transport DTOs that duplicate domain/protocol types without adding transport meaning.
- [ ] Keep session create/actions as thin mapping layers over runtime/domain commands.

Done when transport maps requests/responses and no longer repairs business state.

## Verification

Run per slice:

- [ ] `make rust-check`
- [ ] Targeted `make rust-test` or crate test command for affected modules.
- [ ] Native build/test command for Swift API contract changes.
- [ ] Session smoke: create, detail, send message, subscribe, usage summary, startup restore.
- [ ] Database restore smoke when persistence/compatibility code changes.

Phase 1-specific verification:

- [x] Run validation after Wave 1 before Wave 2 integration.
- [x] Run whole-workspace Rust validation before the Phase 1 commit.
- [x] Sample at least one extracted test file from each worker for naming and layout consistency.
- [x] Confirm no Phase 1 diff changes runtime behavior or broadens production visibility without an explicit note.

Concrete command defaults:

- [ ] Use `make rust-check` for fast shipped-graph compile validation.
- [x] Use `make rust-check-workspace` before the Phase 1 commit.
- [x] Use `make rust-test` once Wave 2 is integrated, or earlier if a touched crate needs a focused confidence pass.

## Definition Of Done

- [ ] Top hotspot files no longer carry large inline test blocks.
- [ ] At least one obsolete surface is deleted end-to-end.
- [ ] Unsupported compatibility code is gone.
- [ ] Protocol files contain active contracts only.
- [ ] Connector event vocabulary is smaller.
- [ ] Remaining tests prove user outcomes and durable server truth.
- [ ] Line-count audit is regenerated and compared to baseline.
