# Server/API Refactor Plan

Date: 2026-04-26

Basis: [server-api-line-audit.md](server-api-line-audit.md) and [server-aggressive-deletion-plan.md](server-aggressive-deletion-plan.md)

Execution branch: `refactor/server-api-plan-execution`

Execution status:

- Current phase: `Phase 10 / Wave 3A execution`
- Current phase detail: `Phase 3 deletion slices 3A through 3Z are complete and validated, Phase 4 regroup is complete, Phase 5 evaluation packets have been integrated, all four Wave 1 lanes are landed, and the defined Wave 2 implementation lanes are landed in commits 04760925, 9d8fb3f7, f1765ded, 6fb0e350, and ba633b99. The Wave 3 regroup and evaluation recut landed in commit 618703d2. After the temporary file-descriptor exhaustion issue was cleared, Wave 3A resumed and two delete-first slices are now landed cleanly: the redundant `SessionSummary::to_list_item` path is gone with `env RUSTC_WRAPPER= cargo test -p orbitdock-protocol --manifest-path orbitdock-server/Cargo.toml` passing, and the dead write-only `ClaudeEventLoopState.last_turn_input` / `turn_output` bookkeeping is gone with `env RUSTC_WRAPPER= cargo test -p orbitdock-connector-claude --manifest-path orbitdock-server/Cargo.toml` passing. The next active cuts remain the Claude `stdout.rs` helper split and the domain session core helper lane. The currently parked redesign seams remain unchanged: Claude shadow ownership/replay ordering, startup/write-side control_mode semantics, single-writer conversation persistence, `session_runtime_helpers.rs`, and `codex_session.rs`.`
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
- `Slice 3AA`: parked for now, not an automatic delete. A broader startup/write-side `control_mode` conversion changed behavior in `load_session_by_id_and_startup_restore_use_persisted_control_mode`, which proves we still support rows where `control_mode = 'direct'` while the legacy integration-mode column remains passive. Do not reopen this lane without a dedicated design pass and new invariants.

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

## Phase 4: Regroup For Reorganization

Objective: switch from pure deletion to delete-plus-split work without losing the discipline that made Phase 3 safe.

Why this phase exists:

- The obvious dead code has already been harvested.
- The next complexity is mostly live code with too many responsibilities per file.
- The failed startup/write-side `control_mode` conversion proved that some remaining mess is behavioral, not just clutter.
- We now need architecture-first reorganization, but every lane should still delete stale helpers, duplicate derived values, and compatibility glue inside the file before splitting.

Target design:

- Each hotspot file should shrink by responsibility, not by arbitrary chunking.
- Each reorganization lane should have one obvious ownership boundary:
  - connector translation
  - runtime orchestration
  - persistence restore/hydration
  - transport mapping
  - protocol contracts
  - CLI/admin/product surfaces
- We keep the known live compatibility seams intact unless a lane explicitly redesigns the invariant:
  - Claude shadow ownership and replay ordering
  - startup/write-side `control_mode` semantics
  - single-writer conversation persistence

Tasks:

- [x] Freeze the reorganization rule: every lane deletes stale code first, then splits what remains.
- [x] Freeze the redesign rule: no worker may “clean up” a proven-live compatibility seam without a named invariant and targeted tests.
- [x] Group hotspot files into disjoint worker-owned lanes.
- [x] Require each worker to produce an evaluation packet before large code movement starts.
- [x] Require a parent regroup checkpoint after evaluation packets and after each implementation wave.

Done when:

- [x] The next phase is organized by ownership boundary, not by generic cleanup.
- [x] Every large-file lane has a worker, scope, and validation contract.
- [x] The plan clearly distinguishes safe split work from redesign-required seams.

## Phase 5: Parallel Evaluation Packets

Objective: evaluate each hotspot lane in parallel before we start cutting production files apart.

Worker output contract:

- Each worker returns one short evaluation packet for its lane.
- Each packet must include:
  - current file/module responsibilities
  - what can be deleted safely before splitting
  - proposed target module layout
  - cross-file dependencies or ownership seams
  - specific risks and tests
  - an implementation order inside the lane
- Workers are read-only in this phase.

Parallel workers:

| Worker | Model | Ownership | Evaluation mission |
| --- | --- | --- | --- |
| Worker A | `gpt-5.4-mini` | `orbitdock-server/crates/connector-claude/src/lib.rs` and adjacent Claude connector files | Map create/session lifecycle/event translation responsibilities, list safe deletions first, and propose the Claude split boundary. |
| Worker B | `gpt-5.4-mini` | `orbitdock-server/crates/connector-core/src/transition.rs` | Separate reducer truth from preview/risk/diff/rendering helpers and identify what can be deleted before any module split. |
| Worker C | `gpt-5.4-mini` | `orbitdock-server/crates/connector-codex/src/app_server.rs` and adjacent Codex connector/session files | Map app-server responsibilities, old runtime/control paths, and propose the split between transport, orchestration, and connector translation. |
| Worker D | `gpt-5.4-mini` | `orbitdock-server/crates/protocol/src/{types,client,server}.rs` plus native protocol mirrors | Identify dead protocol leaves, current active contract groups, and the target protocol module tree after pruning. |
| Worker E | `gpt-5.4-mini` | `orbitdock-server/crates/cli/src/commands/session.rs`, `cli.rs`, and related CLI session surfaces | Decide what is active, what should be frozen or deleted, and what the remaining CLI/session structure should look like. |
| Worker F | `gpt-5.4-mini` | server runtime session core: `runtime/session_command_handler.rs`, `runtime/session_queries.rs`, `runtime/session_creation.rs`, `runtime/session_takeover.rs`, `runtime/restored_sessions.rs` | Map direct-session lifecycle, query/loading, and command handling responsibilities before any split. |
| Worker G | `gpt-5.4-mini` | persistence restore/hydration lane: `infrastructure/persistence/{mod.rs,usage.rs,session_reads/,tests.rs}` | Separate safe read-path simplification from redesign-required startup/write compatibility seams and propose a persistence module breakdown. |
| Worker H | `gpt-5.4-mini` | transport + product-surface lane: `transport/http/session_actions.rs`, `transport/http/session_lifecycle/create.rs`, `admin/`, `runtime/workspace_*`, `runtime/mission_*` | Identify which surfaces should be reorganized, which should be deleted whole, and which should be explicitly frozen. |

Tasks:

- [x] Launch all evaluation workers with disjoint write scopes and read-only instructions.
- [x] Require exact file paths and proposed submodule names in every worker packet.
- [x] Require every packet to classify its lane as `split now`, `delete first`, `needs product call`, or `needs redesign`.
- [x] Integrate the evaluation results into this plan before any worker starts implementation.

Done when:

- [x] Every hotspot lane has a concrete split map.
- [x] Every lane has explicit safe deletions listed up front.
- [x] The parent agent has recut the implementation waves using the evaluation packets.

### Phase 5 launch ledger

| Worker | Agent | Status |
| --- | --- | --- |
| Worker A | `019dd014-b283-7e62-ba2d-42ab39039faa` (`Arendt`) | completed |
| Worker B | `019dd014-b609-7422-b18a-b3e6623c9c0a` (`Herschel`) | completed |
| Worker C | `019dd014-b924-7990-8673-e4bf2c31b1d1` (`Linnaeus`) | completed |
| Worker D | `019dd014-bc53-79f0-81e8-a90da83f0081` (`Hilbert`) | completed |
| Worker E | `019dd015-0317-7a90-a971-fb780a00f707` (`Halley`) | completed |
| Worker F | `019dd015-0648-76b1-ad37-c0140057db98` (`Mendel`) | completed |
| Worker G | `019dd015-09ac-73d3-bbc6-92b93e563e13` (`Goodall`) | completed |
| Worker H | `019dd015-0d05-7ab0-a4de-fc953664f556` (`Leibniz`) | completed |

### Phase 5 evaluation recut

| Lane | Classification | Safe delete-first work | Target split map | Notes |
| --- | --- | --- | --- | --- |
| Claude connector | `split now` | remove dead `Resume`/`Fork`, review ignored per-message `model`/`effort`, trim small wrapper helpers | `session.rs`, `connector.rs`, `protocol.rs`, `images.rs`, `rows.rs`, `stdout.rs` | keep shadow ownership, replay suppression, approval echo, and token accounting intact |
| connector-core transition | `split now` | delete dead reducer wrappers and duplicate approval parser/preview logic after extraction | `transition.rs` plus new `approval_preview.rs` | best first lane because the approval subsystem is pure and the split map is crisp |
| Codex app server | `split now` | delete `path_bufs`, inline `map_generic_tool` after route/mapping extraction | `app_server/{host,router,request_mapping,notification_mapping,item_mapping,response_codec,compat}.rs` | preserve singleton host ownership and request-resolution bijection |
| protocol + native mirrors | `split now` | remove dead WS event leaves in Rust and Swift before module breakup | Rust `messages/client/*`, `messages/server/*`, `types/session/*`; matching native event/session groups | keep `Option<Option<T>>` / `T??` patch semantics and `SessionSurface` invalidation contract |
| CLI session surfaces | `delete first` | remove duplicate bootstrap/subscription helpers and dead local DTO fields | `commands/session/{mod,http,live,bootstrap,watch,presentation,managed}.rs` | public CLI stays stable during Wave 1 |
| runtime session core | `split now` | centralize duplicate status/control/provider parsing and later drop repeated loader fallbacks | `session_queries/*`, `session_restore/*`, `session_command_handler/*`, `session_runtime_launch/*` | do not weaken direct-session ownership or DB-authoritative row ordering |
| persistence restore/hydration | `split now` | extract codecs, remove duplicated hydration assembly, then reuse shared builder | `session_reads/{codecs,projection,hydrator,startup_cleanup}.rs` | do not reopen startup/write-side `control_mode` or Claude shadow guards |
| transport + product surfaces | `needs product call` | no obvious dead routes; safe target is shared mission-session bootstrap extraction | split `session_actions.rs` by controls/conversation/attachments and thin `create.rs` | `/controls` vs `/runtime` remains a product-surface decision, admin is frozen |

### Phase 5 lane packets

#### Worker A: Claude connector

- Current responsibilities: process/bootstrap ownership, outbound Claude protocol shaping, conversation-row shaping, stdout parsing, and the stateful event dispatch/hook/shadow seam.
- Safe delete-first work: dead `ClaudeAction::Resume` and `ClaudeAction::Fork` in `connector-claude/src/session.rs`, plus a review pass on ignored per-message `model` and `effort` fields and tiny wrapper helpers.
- Target split map: keep `session.rs` for public types and carve `connector.rs`, `protocol.rs`, `images.rs`, `rows.rs`, and `stdout.rs` out of `connector-claude/src/lib.rs`.
- Live seam warning: keep replay suppression, managed shadow ownership, approval echo semantics, tool remapping, stream/final dedupe, and token accounting unchanged.
- Lane order: delete dead API first, then extract pure helpers, then the stdout state machine, and only then connector transport.

#### Worker B: connector-core transition

- Current responsibilities: reducer input/type mapping, pure transition reducer, row repair/finalization helpers, and the embedded approval preview/question/risk/rendering subsystem.
- Safe delete-first work: remove the dead `subagent_lists_match` wrapper, likely remove `approval_question_prompts`, and delete the duplicated approval parsing/preview logic parked in `server/src/domain/sessions/approval_state.rs` once the pure approval module exists.
- Target split map: keep `transition.rs` focused on reducer state/types/effects/transition and move approval preview helpers into `connector-core/src/approval_preview.rs`.
- Live seam warning: `Input::ApprovalRequested` remains the one reducer truth path and still owns pending-approval persistence and broadcast semantics.
- Lane order: extract approval subsystem, repoint reducer and external callers, delete dead wrappers/duplication, then move approval-focused tests.

#### Worker C: Codex app server

- Current responsibilities: shared host bootstrap, per-thread route orchestration, connector translation, compatibility shaping, and response encoding.
- Safe delete-first work: remove or inline `path_bufs` and `map_generic_tool` after the route/mapping split clarifies ownership.
- Target split map: thin `app_server.rs` or `app_server/mod.rs` facade with `host.rs`, `router.rs`, `request_mapping.rs`, `notification_mapping.rs`, `item_mapping.rs`, `response_codec.rs`, and `compat.rs`.
- Live seam warning: preserve first-caller-wins host ownership, request/response resolution, route-local stream buffers, and pending-turn context semantics.
- Lane order: response codec first, host second, route orchestration third, request/notification/item mapping fourth, compat last, then cleanup deletes.

#### Worker D: protocol + native mirrors

- Current responsibilities: `types.rs` mixes provider/config/session/approval/worktree/review concerns, while `client.rs` and `server.rs` still aggregate unrelated event families; Swift mirrors carry the same jumbo contract shape.
- Safe delete-first work: delete hard-dead WS leaves such as `ApprovalsList`, `ApprovalDeleted`, `SubagentToolsList`, `PermissionRules`, and the stale Swift-only `claude_models_list`.
- Target split map: Rust `messages/client/*`, `messages/server/*`, `types/session/*`, and smaller topical modules for approvals, providers, inputs, skills, MCP, auth, usage, review, worktrees, and missions; Swift mirrors grouped by event family and shared contracts.
- Live seam warning: preserve Rust `Option<Option<T>>` to Swift `T??` patch semantics, duplicated session field parity, and `SessionSurface` invalidation behavior.
- Lane order: delete dead leaves first, split message envelopes with stable `lib.rs` re-exports, extract session type cluster, then mirror the grouping in Swift.

#### Worker E: CLI session surfaces

- Current responsibilities: CLI parse entrypoints in `cli.rs` and a large `commands/session.rs` that bundles DTOs, bootstrap helpers, REST reads, WS mutations, and presentation/watch behavior.
- Safe delete-first work: delete duplicate `subscribe_session_surface()` and redundant `bootstrap_session_subscription()` calls, remove dead request DTO fields `approval_policy` and `sandbox_mode`, and drop unused response/session list fields.
- Target split map: `commands/session/{mod,http,live,bootstrap,watch,presentation,managed}.rs`, with session-specific CLI parsing split out of `cli.rs` later if still worth it.
- Live seam warning: keep the hidden `managed-session-start` path and the `WsClient` contract stable until a broader product decision says otherwise.
- Lane order: prune dead internals first, then split the command module while keeping the public CLI surface unchanged.

#### Worker F: runtime session core

- Current responsibilities: `session_command_handler.rs` mixes actor routing, persistence mapping, row sync, connector classification, transition execution, and watchdogs; `session_queries.rs`, `session_creation.rs`, `session_takeover.rs`, and `restored_sessions.rs` each carry multiple concerns too.
- Safe delete-first work: centralize duplicated status/control/provider parsing, remove loader fallbacks after a unified load path exists, and delete repeated direct-runtime attach boilerplate once shared launch helpers are in place.
- Target split map: `runtime/session_queries/{library,conversation,state,live_overlay}.rs`, `runtime/session_restore/{mapping,transcript,resume_prep}.rs`, `runtime/session_command_handler/{commands,rows,transitions,connector,persistence}.rs`, and `runtime/session_runtime_launch/*`.
- Live seam warning: keep single direct-session ownership, DB-authoritative row sequencing, immutable provider-session identity, and server-authoritative live overlays.
- Lane order: split restore/parsing/transcript helpers first, then queries, then command handling, and direct-runtime launch last.

#### Worker G: persistence restore/hydration

- Current responsibilities: `session_reads.rs`, `session_hydration.rs`, `startup_recovery.rs`, `ownership_reads.rs`, and `usage.rs` still mix codecs, projections, hydration assembly, startup cleanup, and write-side compatibility logic.
- Safe delete-first work: move codecs into pure helpers, delete duplicated hydration assembly between restore and startup, remove `ActiveSessionRow` after shared projections exist, and pull snapshot-kind decoding out of `usage.rs`.
- Target split map: `session_reads/{mod,codecs,projection,hydrator,startup_cleanup}.rs`, with `ownership_reads.rs` and write-side `usage.rs` staying focused.
- Live seam warning: do not delete startup `control_mode` backfill, `preserve_direct_owned_claude_shadow`, or `persist_set_integration_mode` in this wave.
- Lane order: pure codecs first, shared hydration builder second, startup reuse third, repeated per-session selects fourth, and ownership SQL centralization only if still worth it later.

#### Worker H: transport + product surfaces

- Current responsibilities: `transport/http/session_actions.rs` still mixes controls, conversation mutations, and attachment handling; `session_lifecycle/create.rs` mixes HTTP create flow with mission bootstrap, direct-launch, initial prompt, and mission issue state updates.
- Safe delete-first work: no dead routes proved safe here; the best immediate simplification is extracting the shared mission-session bootstrap from `create.rs` and `runtime/workspace_dispatch/local.rs`.
- Target split map: split `session_actions.rs` into controls query, controls mutations, conversation mutations, and attachments; keep one public `create` handler but move mission/bootstrap helpers under a clearer shared seam.
- Live seam warning: `admin/` is frozen for now, mission/workspace runtime is still strategic, and `/controls` versus `/runtime` remains a product-surface decision rather than a pure refactor.
- Lane order: resolve the product call, thin `session_actions.rs`, extract shared mission bootstrap, then only reorganize mission/workspace code if the surface is still actively strategic.

### Phase 5 implementation recut

Wave 1 implementation order:

1. `connector-core/src/transition.rs`
2. `connector-codex/src/app_server.rs`
3. `connector-claude/src/lib.rs`
4. `protocol/src/{types,client,server}.rs` plus native mirrors

Wave 2 implementation order:

1. runtime session core
2. persistence restore/hydration
3. CLI session surfaces
4. transport + product-surface decisions

## Phase 6: Wave 1 Reorganization

Objective: attack the biggest isolated hotspots first, combining deletion and structural breakup in the same slice.

Wave 1 lanes:

- `connector-claude/src/lib.rs`
- `connector-core/src/transition.rs`
- `connector-codex/src/app_server.rs`
- `protocol/src/{types,client,server}.rs`

Wave 1 worker rules:

- Each worker owns one lane and its explicitly assigned sibling files.
- Delete safe dead helpers, duplicate transit fields, and local compatibility glue first.
- Split only after the lane’s target boundaries are agreed in the evaluation packet.
- Do not change cross-lane contracts without parent approval.

Implementation goals by lane:

- Claude lane:
  - split create/control/event/session glue
  - keep live shadow-ownership rules intact
  - delete stale helper clusters inside the file before carving modules
- Transition lane:
  - keep one authoritative reducer path
  - move preview/risk/diff/rendering helpers out of the reducer module
  - delete cases/helpers no provider emits
- Codex app-server lane:
  - separate transport/app-server bootstrap from direct-session/runtime orchestration
  - delete stale compatibility paths first
- Protocol lane:
  - delete dead types and fields first
  - split active contracts by surface
  - keep native mirror changes in the same lane

Tasks:

- [ ] Land each Wave 1 lane as one coherent commit or a very small series of commits.
- [ ] Run parent validation after each lane, not just at wave end.
- [x] Normalize naming/module layout after the first successful lane so the remaining workers follow the same pattern.
- [x] Update this plan after every landed Wave 1 lane.

### Wave 1 lane ledger

| Lane | Status | Commit | Notes |
| --- | --- | --- | --- |
| Transition / `connector-core/src/transition.rs` | landed | `a46f1117` | Extracted `approval_preview.rs`, rewired the reducer to use it, deleted the duplicate approval prompt parser in `server/src/domain/sessions/approval_state.rs`, and dropped the dead `subagent_lists_match` wrapper. |
| Codex app-server / `connector-codex/src/app_server.rs` | landed | `0e847e40` | Split the app-server lane into `host`, `router`, `request_mapping`, `notification_mapping`, `item_mapping`, `response_codec`, and `compat`, while deleting the stale generic-tool helper and narrowing path conversion. |
| Claude connector / `connector-claude/src/lib.rs` | landed | `a0ef78e0` | Split the lane into `connector`, `protocol`, `images`, `rows`, and `stdout`, and deleted the dead `ClaudeAction::Resume` / `ClaudeAction::Fork` variants without changing shadow/replay behavior. |
| Protocol + native mirrors | landed | `84b327c5` | Followed the dead-leaf prune in `ec30c4ba` by extracting the session contract cluster out of `protocol/src/types.rs` into `protocol/src/types/session.rs`, leaving `server.rs` and `client.rs` untouched and preserving the public re-export surface. |

### Wave 1 validation notes

- Transition lane:
  `env RUSTC_WRAPPER= cargo test -p orbitdock-connector-core --manifest-path orbitdock-server/Cargo.toml`
- Codex lane:
  `env RUSTC_WRAPPER= cargo test -p orbitdock-connector-codex app_server_tests --manifest-path orbitdock-server/Cargo.toml -- --test-threads=1`
- Claude lane:
  `env RUSTC_WRAPPER= cargo test -p orbitdock-connector-claude --manifest-path orbitdock-server/Cargo.toml`
- Shared integration check after landing the first three lanes:
  `env RUSTC_WRAPPER= cargo check -p orbitdock-server --manifest-path orbitdock-server/Cargo.toml`
- Protocol delete-first slice:
  `env RUSTC_WRAPPER= cargo test -p orbitdock-protocol --lib --manifest-path orbitdock-server/Cargo.toml`
- Protocol/native integration check after the dead-leaf prune:
  `env RUSTC_WRAPPER= cargo check -p orbitdock-server --manifest-path orbitdock-server/Cargo.toml`
- Native mirror validation after the dead-leaf prune:
  `xcodebuild -project OrbitDockNative/OrbitDock.xcodeproj -scheme OrbitDock -destination 'platform=macOS' build`
- Protocol structural split:
  `cargo fmt --all --manifest-path orbitdock-server/Cargo.toml`
- Protocol structural split validation:
  `env RUSTC_WRAPPER= cargo test -p orbitdock-protocol --lib --manifest-path orbitdock-server/Cargo.toml`
- Shared integration check after the protocol structural split:
  `env RUSTC_WRAPPER= cargo check -p orbitdock-server --manifest-path orbitdock-server/Cargo.toml`

Done when:

- [x] The top connector/protocol hotspots are materially smaller and more legible.
- [x] At least one lane proves the “delete first, split second” pattern works in practice.
- [x] Cross-lane contracts are still stable after Wave 1 validation.

## Phase 7: Wave 2 Reorganization And Surface Decisions

Objective: reorganize the server crate hotspots and decide which broader surfaces should be kept, frozen, or removed.

Wave 2 lanes:

- runtime session core
- persistence restore/hydration/usage
- transport HTTP session surfaces
- CLI/admin/product surfaces

Parallel workers:

| Worker | Model | Ownership | Implementation mission |
| --- | --- | --- | --- |
| Worker F1 | `gpt-5.4-mini` | runtime session core query/load path | Split read/query/bootstrap responsibilities out of `session_queries.rs`, `restored_sessions.rs`, and adjacent load helpers while preserving direct-session invariants. |
| Worker F2 | `gpt-5.4-mini` | runtime session command/lifecycle path | Break `session_command_handler.rs` and adjacent lifecycle files along command classification, persistence sync, and connector dispatch boundaries. |
| Worker G1 | `gpt-5.4-mini` | persistence read path | Continue safe delete-plus-split work in `session_reads/`, `usage.rs`, and related read-only helpers, but keep parked startup/write compatibility seams intact. |
| Worker G2 | `gpt-5.4-mini` | transport mapping | Thin `session_actions.rs`, `session_lifecycle/create.rs`, and related HTTP mapping files down to transport concerns only. |
| Worker H1 | `gpt-5.4-mini` | CLI/admin | Reorganize active CLI/admin code and prepare delete decisions for any clearly obsolete session/admin surfaces. |
| Worker H2 | `gpt-5.4-mini` | mission/workspace/product surfaces | Decide `keep`, `freeze`, or `delete` for mission/workspace/admin-adjacent surfaces before we spend more reorganization effort on them. |

### Phase 7 launch ledger

| Worker | Agent | Status |
| --- | --- | --- |
| Worker F1 | `019dd0e9-4ccb-7852-9212-38ab5c08f60b` (`Schrodinger`) | completed |
| Worker F2 | `019dd0e9-5049-7ae1-a521-364e99d3c666` (`Tesla`) | completed |
| Worker G1 | `019dd0e9-53e5-7132-94a7-c4afe0488446` (`Turing`) | completed |
| Worker G2 | `019dd0e9-5703-75e1-bf2d-830fe3468cbf` (`Pasteur`) | completed |
| Worker H1 | `019dd0e9-5a57-7a61-8a70-bc0c89c731e1` (`Parfit`) | completed |
| Worker H2 | `019dd0e9-5def-71b1-907c-40ed6b83967a` (`Hypatia`) | completed |

### Phase 7 implementation ledger

| Lane | Status | Commit | Notes |
| --- | --- | --- | --- |
| Runtime query/load path | landed | `04760925` | Split `session_queries.rs` and `restored_sessions.rs` into facade roots with focused `session_queries/*` and `session_restore/*` modules for projection, conversation, detail, parsing, hydration, direct resume, and restored-session state assembly. |
| Runtime command/lifecycle path | landed | `9d8fb3f7` | Split `session_command_handler.rs` into a thinner router with dedicated `session_command_persistence.rs` and `session_connector_dispatch.rs`, and removed the duplicate row-sequence helper from `conversation_policy.rs`. |
| Persistence read path | landed | `f1765ded` | Split `session_reads.rs` into `codecs`, `projections`, and `hydration` helpers, moved duplicated restored-session assembly behind shared builders, and kept the parked startup compatibility seams intact. |
| Transport mapping | landed | `6fb0e350` | Split `session_actions.rs` into `common`, `controls`, `messages`, and `attachments`, and extracted Codex create request mapping into `session_lifecycle/create_mapping.rs`. |
| CLI session surfaces | landed | `ba633b99` | Split the CLI session surface into `bootstrap`, `http`, `live`, `watch`, and `presentation`, while removing the duplicate approve/answer bootstrap path and preserving the public CLI behavior. |

### Phase 7 surface calls so far

- `freeze`: `server/src/admin/`
- `freeze`: `server/src/transport/http/server_info/`
- `keep`: `server/src/runtime/mission_*`
- `keep`: `server/src/runtime/workspace_*`
- `keep`: `server/src/transport/http/mission_control/*`
- `keep`: `cli/src/commands/session*`
- `delete`: no whole-surface delete is justified yet in the mission/workspace/admin lane

Interim notes:

- The admin and server-info surfaces still serve live operational workflows, but they look stable enough to freeze instead of spending reorganization effort there right now.
- The mission, workspace, and mission-control surfaces still map to active user workflows, so they stay in `keep` and should only be reorganized if a later lane needs it.
- The next clean ownership sets after the current Wave 2 implementation lanes are mission runtime, workspace runtime, and the decomposed `transport/http/mission_control/*` tree.

Decision rules:

- `keep`
  - Name the active user workflow.
  - Reorganize only if the surface is still strategic.
- `freeze`
  - Stop investing in cleanup beyond smoke-level stability.
  - Avoid spreading its abstractions into newer lanes.
- `delete`
  - Remove route/runtime/protocol/native/CLI/docs/tests together in one surface slice.

Tasks:

- [x] Split runtime session files by lifecycle, query/load, and connector-dispatch responsibility.
- [x] Split persistence files by restore/hydration/usage ownership where safe.
- [x] Keep startup/write-side `control_mode` compatibility parked unless a dedicated redesign begins.
- [x] Mark mission/workspace/admin/CLI surfaces `keep`, `freeze`, or `delete`.
- [x] Land whole-surface deletions only after the owning worker packet and parent review agree.
  Result: no whole-surface deletion was justified in this wave, so the lane closed with explicit `keep`/`freeze` calls instead of forced cuts.

Done when:

- [x] The main server hotspots are smaller and responsibility-aligned.
- [x] We have explicit keep/freeze/delete calls for the broad product/tooling surfaces.
- [x] Remaining complexity is concentrated in named live seams, not spread across giant files.

## Phase 8: Remaining-Hotspot Regroup

Objective: recut the post-Wave-2 top-pressure files into a new attack plan before we start another implementation wave.

Current top remaining production hotspots driving this phase:

- `connector-codex/src/rollout_parser.rs`
- `connector-core/src/transition.rs`
- `protocol/src/types.rs`
- `connector-claude/src/stdout.rs`
- `protocol/src/conversation_contracts/tool_display.rs`
- `server/src/domain/sessions/state.rs`
- `protocol/src/conversation_contracts/rows.rs`
- `cli/src/cli.rs`
- `cli/src/dev_console.rs`
- `connector-codex/src/app_server/item_mapping.rs`

Guiding rule:

- Do not split for the sake of smaller files alone.
- Delete stale helpers first when safe.
- Then split along one of three boundaries only: protocol contract groups, provider event/translation stages, or domain state ownership seams.

## Phase 9: Wave 3 Evaluation

Objective: map the remaining large live files into clear implementation lanes with explicit `split now`, `freeze`, `delete first`, or `needs redesign` calls.

Worker output contract:

- Each worker returns one short evaluation packet for its lane.
- Each packet must include:
  - current responsibilities
  - safe delete-first work
  - target module layout
  - live seams and risks
  - tests to run
  - implementation order inside the lane

Parallel workers:

| Worker | Model | Ownership | Evaluation mission |
| --- | --- | --- | --- |
| Worker A | `gpt-5.4-mini` | `connector-codex/src/rollout_parser.rs`, `connector-codex/src/app_server/item_mapping.rs`, `connector-codex/src/session_ops.rs`, `connector-codex/src/config.rs` | Separate pure rollout parsing from file watching, normalization, item mapping, and config shaping; identify what can still be deleted before the next Codex connector split. |
| Worker B | `gpt-5.4-mini` | `connector-claude/src/stdout.rs`, plus adjacent `rows.rs` and `protocol.rs` only if needed for boundary mapping | Map the Claude stdout/event-loop state machine, line parsing stages, approval/control handling, and row reconstruction seams so we can split it without touching shadow ownership semantics. |
| Worker C | `gpt-5.4-mini` | `protocol/src/types.rs`, `protocol/src/types/session.rs`, `protocol/src/conversation_contracts/tool_display.rs`, `protocol/src/conversation_contracts/rows.rs` | Recut the remaining protocol surface into contract groups and identify whether rendering-heavy row/tool-display logic should split before any more type churn. |
| Worker D | `gpt-5.4-mini` | `server/src/domain/sessions/state.rs`, `server/src/domain/sessions/session.rs`, and nearby pure domain helpers only when needed | Map the domain session core and identify which state ownership seams should split next without weakening actor/domain authority. |
| Worker E | `gpt-5.4-mini` | `cli/src/cli.rs`, `cli/src/dev_console.rs`, and the active CLI session shell only when needed for context | Decide whether the remaining CLI shell surfaces are `split now` or `freeze`, and name the exact ownership sets if they still deserve active refactor effort. |
| Worker F | `gpt-5.4-mini` | `server/src/infrastructure/persistence/{mod.rs,usage.rs,session_writes.rs}`, `server/src/runtime/{session_runtime_helpers.rs,message_dispatch.rs,session_takeover.rs}`, `server/src/connectors/{codex_session.rs,codex_hooks/mod.rs,claude_session.rs}` | Group the remaining server operational hotspots into the next realistic ownership sets and call out any delete-first or freeze-first opportunities before we touch them. |

Tasks:

- [x] Launch all Wave 3 evaluation workers with disjoint ownership.
- [x] Require every packet to classify its lane as `split now`, `delete first`, `freeze`, or `needs redesign`.
- [x] Integrate the packets back into this plan before starting the next implementation wave.

### Phase 9 launch ledger

| Worker | Agent | Status |
| --- | --- | --- |
| Worker A | `019dd0fe-6f81-7983-b21a-9d35c7588036` (`Laplace`) | completed |
| Worker B | `019dd0fe-7334-7830-996d-6aef39ccf40e` (`Gauss`) | completed |
| Worker C | `019dd0fe-76fd-70d0-9d81-806f494ae746` (`Bacon`) | completed |
| Worker D | `019dd0fe-7b2a-79c0-a21f-b260ad1e3ee7` (`Avicenna`) | completed |
| Worker E | `019dd0fe-7e56-79d3-b877-c79be0115a1c` (`Ramanujan`) | completed |
| Worker F | `019dd0fe-81b0-7ef1-9408-f78289301979` (`Euler`) | completed |

### Phase 9 evaluation recut

#### Worker A: Codex connector parser + mapping lane

- Classification: `split now`
- `rollout_parser.rs` is already close to a stable parsing seam, but `config.rs`, `session_ops.rs`, and `app_server/item_mapping.rs` still mix transport shaping, bridge helpers, connector state mutation, and runtime bootstrap.
- Safe delete-first work:
  - centralize the duplicated generic conversion helpers shared by `config.rs` and `session_ops.rs`
  - collapse the overloaded constructor/restore parameter ladders in `config.rs`
  - only split filesystem and git helpers out of `rollout_parser.rs` after the pure parser core is isolated
- Target layout:
  - `config/bootstrap.rs`
  - `config/policy.rs`
  - `session/commands.rs`
  - `session/bridge.rs`
  - `app_server/item_mapping/{tool_rows,messages,collab_agents,dynamic_tools,review_mode}.rs`
  - `rollout/{parser,fs,subagents}.rs`
- Live seam warning:
  - `session_ops.rs` is still a direct connector-state owner
  - `item_mapping.rs` mixes pure mapping with route-local stream-state coordination
  - `rollout_parser.rs` still mixes pure parsing with some filesystem/process-side helpers
- Lane order:
  1. extract shared conversion/request helpers
  2. split `config.rs`
  3. split `session_ops.rs`
  4. refactor `item_mapping.rs`
  5. leave `rollout_parser.rs` for the tail unless the FS helpers are already moving

#### Worker B: Claude stdout lane

- Classification: `delete first`
- `stdout.rs` currently owns the entire Claude stdout lifecycle: line parsing, replay suppression, turn lifecycle, message routing, streaming assistant state, tool/task reconciliation, PTY side effects, and approval/control translation.
- Safe delete-first work:
  - remove the write-only `ClaudeEventLoopState.last_turn_input`
  - remove the write-only `ClaudeEventLoopState.turn_output`
- Target layout:
  - keep `stdout.rs` as the orchestration facade
  - split into `stdout/state.rs`, `stdout/control.rs`, `stdout/system.rs`, `stdout/messages.rs`, and `stdout/helpers.rs`
- Live seam warning:
  - preserve the parked replay and shadow seam exactly
  - keep replay filtering aligned with `--replay-user-messages` in `connector.rs` and the shadow cleanup guard in `session.rs`
  - fragile edges include `task_tool_use_map`, `tool_rows`, stream flush ordering, and `ExitPlanMode` ordering
- Lane order:
  1. delete the write-only turn fields
  2. run `cargo test -p orbitdock-connector-claude --manifest-path orbitdock-server/Cargo.toml`
  3. extract control and approval helpers
  4. extract system handlers
  5. extract message and stream handlers

#### Worker C: Protocol rendering + session contract lane

- Classification: `delete first`
- `types.rs` is the protocol spine rather than dead junk, `types/session.rs` owns session-facing projections and display helpers, and `conversation_contracts/tool_display.rs` is already a clean pure renderer seam.
- Safe delete-first work:
  - remove `SessionSummary::to_list_item` from `protocol/src/types/session.rs`
  - keep `SessionListItem::from_summary` as the single canonical constructor
- Target layout:
  - keep `types/session.rs` as the session projection root
  - optionally later split `types/session_display.rs` or `types/session_projection.rs`
  - keep `tool_display.rs` intact
  - later split `rows.rs` into `model`, `summary`, and `transport` only if still justified
- Live seam warning:
  - `display_title_from_parts`, `context_line_from_parts`, and `list_status_from_parts` are broadly used
  - `ToolDisplay` remains a client-decoded wire contract
  - `ConversationRowSummary::into_transport_summary` is a transport safety gate
- Lane order:
  1. delete `SessionSummary::to_list_item`
  2. run protocol tests
  3. only then consider a smaller `types/session.rs` display split
  4. treat `rows.rs` as a later follow-on, not the first cut

#### Worker D: Domain session core lane

- Classification: `split now`
- The architecture boundary is already mostly present: `state.rs` is the mutable domain core and `session.rs` is the runtime shell for broadcast, snapshotting, and replay.
- Safe delete-first work:
  - move `is_local_http_row_id` and `latest_transcript_synced_row_id` out of `state.rs` into a shared row or conversation helper
  - delete duplicate pure helper logic from `session.rs` once the shared helpers exist
  - only remove the temporary transition bridge after callers no longer depend on `extract_state` and `apply_state`
- Target layout:
  - keep `state.rs` or rename later to `session_core.rs` as the domain authority
  - keep `session.rs` or rename later to `session_handle.rs` as the runtime shell
  - extract `support/session_modes.rs` for shared pure predicates
  - extract a tiny row-sync or conversation helper for transcript-anchor logic and row-retention policy
- Live seam warning:
  - snapshot refresh is currently manual and uneven
  - `StateChanges` can carry `control_mode`, but `SessionCoreState::apply_changes` does not consume it
  - `broadcast()` still mixes transport sanitization, replay-log serialization, surface invalidation, and dashboard invalidation
- Lane order:
  1. freeze behavior with targeted tests
  2. extract `session_modes` and row-sync helpers
  3. tighten one obvious snapshot refresh path for snapshot-affecting mutations
  4. remove the temporary transition bridge later, not in the first cut

#### Worker E: CLI shell lane

- Classification: `split now`
- `cli.rs` still bundles binary-level clap parsing, client-facing command parsing, and shared conversion helpers, while `dev_console.rs` is cohesive but overstuffed with runtime, state, rendering, input, and terminal lifecycle concerns.
- Safe delete-first work:
  - no obvious dead code today
  - the binary-to-client bridge is still live and should only be revisited after the split proves it is redundant
- Target layout:
  - `cli/{binary,client,shared}.rs`
  - `dev_console/{runtime,state,render,input}.rs`
- Live seam warning:
  - `main.rs` depends on the binary-versus-client dispatch split
  - `dev_console.rs` is TTY-sensitive and suspends raw mode around pager processes
  - selection/filter/category logic is a real behavior seam
- Lane order:
  1. split `cli.rs` into `shared`, `binary`, and `client`
  2. move `resolve_stdin`
  3. split `dev_console.rs` into state, render, runtime, and input or effects
  4. only then revisit whether the translation bridge can ever be deleted

#### Worker F: Server operational lane

- Mixed classification:
  - `persistence/mod.rs`: `split now`
  - `persistence/usage.rs`: `freeze`
  - `persistence/session_writes.rs`: `split now`
  - `runtime/session_runtime_helpers.rs`: `needs redesign`
  - `runtime/message_dispatch.rs`: `split now`
  - `runtime/session_takeover.rs`: `split now`
  - `connectors/codex_session.rs`: `needs redesign`
  - `connectors/codex_hooks/mod.rs`: `split now`
  - `connectors/claude_session.rs`: `freeze`
- Safe delete-first work:
  - delete alias wrappers in `message_dispatch.rs` only after transport callsites move to canonical verbs
  - delete duplicate cleanup fallback writes in `session_runtime_helpers.rs` only after one cleanup transition owns state change
  - delete hook-side shadow-materialization helpers in `codex_hooks/mod.rs` only after routing and bootstrap are separated
  - do not delete `preserve_direct_owned_claude_shadow`
- Target layout:
  - `persistence/session_state`: `mod.rs` + `session_writes.rs` + small shadow helpers
  - `persistence/usage_accounting`: keep `usage.rs` intact
  - `runtime/session_actions`: `message_dispatch.rs` + `session_takeover.rs`
  - `runtime/session_lifecycle`: later redesign split for `session_runtime_helpers.rs`
  - `connectors/codex`: redesign lane for `codex_session.rs`
  - `connectors/hooks`: split `codex_hooks/mod.rs` into routing, bootstrap, and metadata-sync
- Live seam warning:
  - competing direct-session cleanup paths
  - repeated provider-specific branching across dispatch, takeover, and hooks
  - process-global transcript-sync cache in `session_runtime_helpers.rs`
  - `codex_session.rs` still spans connector runtime, workspace diffing, and mission side effects
- Lane order:
  1. clean up `message_dispatch.rs` aliases and separate command families
  2. split `session_takeover.rs`
  3. carve `codex_hooks/mod.rs`
  4. leave `session_runtime_helpers.rs` and `codex_session.rs` for a dedicated redesign wave

Done when:

- [x] Every remaining top-pressure file belongs to a named lane.
- [x] The next implementation wave is split into coherent ownership sets.
- [x] We have explicit `keep`/`freeze` calls for the remaining CLI and operational surfaces.

## Phase 10: Wave 3 Implementation

Objective: land the highest-confidence remaining split and delete-first lanes without reopening the parked redesign seams.

Wave 3A implementation order:

1. protocol tiny delete-first cleanup
2. Claude stdout delete-first plus helper split
3. domain session core helper extraction and snapshot-refresh tightening

Wave 3B implementation order:

1. Codex connector shared conversion, `config.rs`, and `session_ops.rs`
2. CLI shell split
3. server operational split-now lane: `message_dispatch.rs`, `session_takeover.rs`, `persistence/mod.rs`, `session_writes.rs`, `codex_hooks/mod.rs`

Wave 3C parked redesign lanes:

- `server/src/runtime/session_runtime_helpers.rs`
- `server/src/connectors/codex_session.rs`
- any broader revisit of startup or write-side `control_mode`

Parallel workers:

| Worker | Model | Ownership | Implementation mission |
| --- | --- | --- | --- |
| Worker A1 | `gpt-5.4-mini` | protocol tiny delete-first lane | Remove `SessionSummary::to_list_item`, validate the session projection seam, and only split display helpers if the delete-first pass leaves clear value. |
| Worker B1 | `gpt-5.4-mini` | Claude stdout lane | Delete the write-only turn fields, then split control/system/message helper clusters out of `stdout.rs` while preserving replay and shadow semantics. |
| Worker D1 | `gpt-5.4-mini` | domain session core lane | Extract shared pure helpers for session modes and transcript sync, then tighten the runtime-shell snapshot refresh path without changing authority boundaries. |
| Worker A2 | `gpt-5.4-mini` | Codex connector lane | Extract shared bridge helpers, split `config.rs` and `session_ops.rs`, and only then decide whether `item_mapping.rs` should move in the same wave. |
| Worker E1 | `gpt-5.4-mini` | CLI shell lane | Split `cli.rs` and `dev_console.rs` into clearer parser/runtime/rendering ownership sets while preserving the current CLI surface. |
| Worker F1 | `gpt-5.4-mini` | server operational split-now lane | Split `message_dispatch.rs`, `session_takeover.rs`, `persistence/mod.rs`, `session_writes.rs`, and `codex_hooks/mod.rs` without touching the parked redesign files. |

Execution rules:

- Do not open Wave 3C redesign work until Wave 3A and 3B are landed and validated.
- Keep `protocol/src/conversation_contracts/tool_display.rs`, `persistence/usage.rs`, and `connectors/claude_session.rs` frozen unless a touched lane forces a small local change.
- If `connector-codex/src/rollout_parser.rs` still looks large after the Codex lane, treat it as a tail cleanup inside the Codex ownership set rather than a separate free-floating lane.

Tasks:

- [x] Launch Wave 3A workers first and validate after each landed slice.
- [ ] Launch Wave 3B only after Wave 3A conventions are confirmed.
- [ ] Keep Wave 3C explicitly parked until a dedicated redesign phase is written.

### Phase 10 launch ledger

| Worker | Agent | Status |
| --- | --- | --- |
| Worker A1 | `019dd104-c9f3-7723-a893-52015a4eeacc` (`Ampere`) | completed - blocked by environment, no edits |
| Worker B1 | `019dd105-3845-7560-9ca2-e65b1c6a2ab8` (`Aristotle`) | completed - blocked by environment, no edits |
| Worker D1 | `019dd104-c660-78a2-a622-95803ca0e22c` (`McClintock`) | completed - blocked by environment, no edits |
| Worker A2 | pending | not launched |
| Worker E1 | pending | not launched |
| Worker F1 | pending | not launched |

### Phase 10 execution note

- The first two Wave 3A slices are now landed locally: the protocol lane removed the redundant `SessionSummary::to_list_item` constructor, and the Claude lane removed the dead write-only `last_turn_input` / `turn_output` bookkeeping from `stdout.rs`.
- The temporary workspace-wide file-descriptor exhaustion (`Too many open files`) is resolved for now, but the blocked worker notes remain useful context for the next two lanes.
- Resume order remains: Claude `stdout.rs` helper extraction, then the domain session helper extraction, then Wave 3B if those conventions stay clean.

Done when:

- [ ] The remaining split-now and delete-first lanes from Phase 9 are either landed or explicitly reclassified.
- [ ] The parked redesign seams are still isolated and documented.
- [ ] The next regroup is about true redesign, not obvious module breakup work we should have already done.

## Verification

Run per slice:

- [x] `make rust-check`
- [ ] Targeted `make rust-test` or crate test command for affected modules.
- [ ] Native build/test command for Swift API contract changes.
- [ ] Session smoke: create, detail, send message, subscribe, usage summary, startup restore.
- [ ] Database restore smoke when persistence/compatibility code changes.
- [ ] Re-run the isolated regression test that justified any parked seam before reopening that lane.

Phase 1-specific verification:

- [x] Run validation after Wave 1 before Wave 2 integration.
- [x] Run whole-workspace Rust validation before the Phase 1 commit.
- [x] Sample at least one extracted test file from each worker for naming and layout consistency.
- [x] Confirm no Phase 1 diff changes runtime behavior or broadens production visibility without an explicit note.

Concrete command defaults:

- [x] Use `make rust-check` for fast shipped-graph compile validation.
- [x] Use `make rust-check-workspace` before the Phase 1 commit.
- [x] Use `make rust-test` once Wave 2 is integrated, or earlier if a touched crate needs a focused confidence pass.

## Definition Of Done

- [x] Top hotspot files no longer carry large inline test blocks.
- [x] The top production hotspots are split by responsibility, not just shortened.
- [x] Obsolete surfaces are either deleted end-to-end or explicitly marked `freeze` with rationale.
- [x] Unsupported compatibility code is gone, and proven-live seams are explicitly documented instead of “cleaned up” by guesswork.
- [x] Protocol files contain active contracts only.
- [x] Connector event vocabulary is smaller and easier to trace.
- [ ] Remaining tests prove user outcomes and durable server truth.
- [x] Line-count audit is regenerated and compared to baseline.
