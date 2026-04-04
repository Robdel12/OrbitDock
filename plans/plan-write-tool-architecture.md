# Plan Write Tool Architecture Plan

Date: 2026-04-03  
Owner: OrbitDock Server Team  
Status: Ready for implementation

## 1. Problem Statement And Goals

### Problem
- OrbitDock currently treats plan output (`update_plan` and plan mode) as timeline/state data only.
- There is no intentional, first-class way for the agent to persist a plan artifact into repo `plans/`.
- Automatic writes on every `PlanUpdated` event would be noisy and create churn.

### Goals
- [x] Add an explicit `plan_write` dynamic tool that writes markdown plans into `plans/`.
- [x] Keep writes intentional (tool-triggered), not automatic on every plan event.
- [x] Preserve existing plan timeline/state behavior (`PlanUpdated` remains non-mutating state sync).
- [x] Ensure tool output maps to native file-change tool cards (`Write`) in conversation UI.

### Non-Goals
- [x] Do not auto-export plans on every `PlanUpdated`.
- [x] Do not redesign plan mode semantics or `update_plan` protocol contracts.
- [x] Do not add a new persistence table or background plan-export worker.

## 2. Why This Change Now
- `file_read` / `file_write` / `file_edit` are already working and adopted, so the missing piece is explicit plan artifact persistence.
- Teams are increasingly using architecture plans as execution handoff docs; losing them to ephemeral timeline state creates rework.
- A dedicated tool allows strong guardrails (`plans/` only) while avoiding accidental write spam.

## 3. Current State And Constraints
- Dynamic workspace tools are defined/executed in `orbitdock-server/crates/server/src/domain/codex_tools.rs`.
- Dynamic tool rendering/mapping is resolved in `orbitdock-server/crates/connector-codex/src/event_mapping/tools.rs`.
- Session state currently stores `current_plan` from `PlanUpdated` via transition flow, and this should stay intact.
- Paths must remain project-root constrained and consistent with existing file tool safety patterns.

## 4. Architecture Proposal

### System Boundaries
- `plan_write` is a workspace dynamic tool (same layer as `file_write`), not a mission tool.
- It is the only mutating path for plan artifact persistence in this scope.
- `PlanUpdated` remains read-model state and timeline updates only.

### Tool Contract (v1)
- Name: `plan_write`
- Description: write a markdown plan file under `plans/`.
- Input:
  - `path` (required): relative/absolute target path; must resolve under repo `plans/`.
  - `content` (required): full markdown document content to write.
  - `overwrite` (optional, default `false`): if `false`, fail when target exists.

### Path And Safety Rules
- Resolve path relative to current cwd/project root (matching existing workspace behavior).
- Enforce target file is inside canonical repo `plans/` directory.
- Create `plans/` if missing.
- Reject directory targets.
- Reject writes outside `plans/`.
- Respect overwrite gate (`overwrite=false` returns a clear error if file exists).

### Data Flow
1. Model calls dynamic tool `plan_write`.
2. `execute_codex_workspace_tool` dispatches to `exec_plan_write`.
3. Tool validates path + guardrails, writes file, returns JSON payload with:
   - `path`
   - `bytes_written`
   - `plan_written: true`
4. Connector event mapping classifies response as `FileChange/Write` so UI uses native write affordances.

### Ownership
- Tool behavior and safety: `codex_tools.rs`.
- Display classification and response shaping: `event_mapping/tools.rs`.
- Plan event behavior: unchanged in `connector-core` transition and runtime signals.

## 5. Alternatives Considered

1. Auto-write on `PlanUpdated`
- Pros:
  - Zero extra model/tool call.
- Cons:
  - High write churn from iterative plan edits.
  - Harder to control filename and commit-worthy snapshots.
  - Risk of noisy diffs and accidental artifacts.
- Why rejected:
  - Violates intent to keep persistence explicit and low-noise.

2. Hybrid auto-draft + explicit finalize
- Pros:
  - Convenience plus explicit final save.
- Cons:
  - More complexity (draft lifecycle, cleanup, naming policy).
  - More moving parts than required for immediate value.
- Why rejected:
  - Better as a future enhancement after `plan_write` adoption data.

## 6. Risks And Mitigations
| Risk | Impact | Mitigation | Owner |
|---|---|---|---|
| Path escape bug writes outside repo | High | Canonical path checks against project root and `plans/` root | Server |
| File overwrite surprises | Medium | Default `overwrite=false` with explicit error | Server |
| UI shows generic tool card | Medium | Map `plan_write` to native `FileChange/Write` identity | Connector |
| Markdown quality inconsistent | Low | Keep tool raw-content based; prompt and plan templates govern quality | Product/Prompt |

## 7. Phased Execution Checklist

### Phase 1: Tool Surface And Safety
Objective: Add `plan_write` tool spec + guarded write executor.
Dependencies: None
Exit Criteria:
- [x] `plan_write` appears in default dynamic tools.
- [x] Writes only succeed for files under repo `plans/`.
- [x] Overwrite gate behaves correctly.
Tasks:
- [x] Add `plan_write` definition and schema in `orbitdock-server/crates/server/src/domain/codex_tools.rs`.
- [x] Implement `exec_plan_write` and path guard helpers in `orbitdock-server/crates/server/src/domain/codex_tools.rs`.
- [x] Add/extend unit tests in `orbitdock-server/crates/server/src/domain/codex_tools.rs`.

### Phase 2: Conversation Tool Mapping
Objective: Ensure `plan_write` renders as native write semantics.
Dependencies: Phase 1
Exit Criteria:
- [x] Dynamic tool request row classifies `plan_write` as `FileChange/Write`.
- [x] Response row summary/result fields mirror native write output behavior.
Tasks:
- [x] Extend name-based mapping in `orbitdock-server/crates/connector-codex/src/event_mapping/tools.rs`.
- [x] Add focused tests in `orbitdock-server/crates/connector-codex/src/event_mapping/tools.rs`.

### Phase 3: Validation And Documentation Touchups
Objective: Confirm end-to-end behavior and document intended usage.
Dependencies: Phase 1, Phase 2
Exit Criteria:
- [x] Targeted Rust tests pass.
- [x] Plan tool behavior is captured in a repo plan artifact (this document).
Tasks:
- [x] Run `cargo test -p orbitdock-server codex_tools`.
- [x] Run `cargo test -p orbitdock-connector-codex dynamic_tool`.
- [x] Sanity-check generated tool JSON includes `plan_write`.

## 8. Parallel Worker Lanes
| Lane | Owner | Scope | Can Start After | Integration Point |
|---|---|---|---|---|
| Lane A | Server Worker | `codex_tools.rs` tool spec + executor + tests | Immediately | Merge before mapping validation |
| Lane B | Connector Worker | `event_mapping/tools.rs` identity mapping + tests | Immediately | Rebases once Lane A tool name is finalized |
| Lane C | Verification Worker | Targeted test runs and payload sanity checks | After A+B code complete | Final validation pass |

### Coordination Notes
- Shared contract: tool name `plan_write` and output keys (`path`, `bytes_written`, `plan_written`).
- Merge order: Lane A, then Lane B, then Lane C.
- Conflict risk: low (disjoint files); only shared risk is output payload expectations in tests.

## 9. Decision Log
| Date | Decision | Context | Owner | Status |
|---|---|---|---|---|
| 2026-04-03 | Add explicit `plan_write` tool | Need intentional plan artifact persistence | Team | Resolved |
| 2026-04-03 | Do not auto-write on `PlanUpdated` | Avoid write churn/noisy diffs | Team | Resolved |
| 2026-04-03 | Require writes under `plans/` only | Protect repo from broad write surface | Team | Resolved |

## 10. Validation And Rollout Plan
- Validation strategy:
  - Unit tests for path validation, overwrite behavior, and successful writes.
  - Connector tests for dynamic tool row classification and summaries.
- Commands:
  - [x] `cargo test -p orbitdock-server codex_tools`
  - [x] `cargo test -p orbitdock-connector-codex dynamic_tool`
- Rollout:
  - Ship behind normal branch flow; no migration required.
  - Monitor for tool-call failures containing `plan_write` errors.
- Rollback:
  - Revert `plan_write` addition in `codex_tools.rs` and mapping in `event_mapping/tools.rs`.
  - No data migration or state cleanup needed.

## 11. Immediate Next Actions
- [x] Implement Phase 1 tool surface and safety checks — Owner: OrbitDock Server Team — Due: 2026-04-03
- [x] Implement Phase 2 mapping and tests — Owner: OrbitDock Connector Team — Due: 2026-04-03
- [x] Run Phase 3 targeted validation commands — Owner: OrbitDock Server Team — Due: 2026-04-03
