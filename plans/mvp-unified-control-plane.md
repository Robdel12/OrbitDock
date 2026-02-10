# OrbitDock Unified Control Plane — MVP Plan

> Single source of truth for finishing the server-owned session architecture.
> Last updated: 2026-02-09

## MVP Goal

Ship a reliable OrbitDock where `orbitdock-server` is the only session engine for both Codex and Claude:

- Session/message lifecycle is server-owned.
- App is a reactive client over WebSocket state.
- DB is an implementation detail behind server persistence.

## Product Definition (MVP)

A user should be able to:

1. Start and continue Claude + Codex sessions.
2. See active/inactive state transitions reliably.
3. See stable, useful session names.
4. Restart OrbitDock and recover expected session state/history.
5. Debug session issues from server logs + DB without app-side ambiguity.

## What Is Already Done

### Server ownership foundation

- [x] Rust server owns direct Codex session lifecycle.
- [x] Rust rollout watcher owns passive Codex transcript lifecycle.
- [x] Claude hooks are routed through server transport from CLI commands.
- [x] Server protocol includes Claude hook event message types.
- [x] Server persistence handles unified session updates.
- [x] Server-authoritative session list is used in app (`ContentView` from `serverState.sessions`).

### Hardening completed

- [x] Direct/passive Codex dedup guardrails and thread-shadow protections.
- [x] Passive identity self-healing in persistence (`provider=codex`, `mode=passive`, `thread_id`).
- [x] Rollout reactivation/list sync fixes for active/inactive consistency.
- [x] Shared naming function for Claude + Codex first-prompt naming.
- [x] Startup name backfill from rollout history when needed.
- [x] Build pipeline rebuilds/embeds current server binary in app runs.
- [x] Structured app/server logging in `~/.orbitdock/logs`.

## Remaining MVP Work

## Workstream 1: Remove Remaining Split-Brain Paths

Goal: no hidden app-side lifecycle engine.

- [x] Remove remaining app DB fallback logic for session/message lifecycle decisions.
- [ ] Remove app-side Codex subscription behavior for non-server-managed assumptions.
- [ ] Ensure historical reads needed by UI are served via server APIs/snapshots.
- [ ] Add a code-level guard/checklist: no new session lifecycle logic outside server.

Progress log (2026-02-10):
- Routed session close + rename actions in app shell UI through `ServerAppState` only (`QuickSwitcher`, `AgentListPanel`), removing direct DB mutation paths for session lifecycle/name decisions.
- Removed `ContentView` EventBus/database session refresh loop; top-level session identity/state now tracks server list updates only.
- Moved menu bar session list source to `ServerAppState.sessions` and added server list refresh action via `subscribe_list`.
- Fixed passive live-reactivation UI gap by treating `session_created` as an upsert in app state (existing session rows now refresh on ended -> active transitions).
- Added server-side watcher regression coverage for closed passive session reactivation, including runtime state and persisted DB state (`ended_*` cleared on new rollout user activity).
- Added close->append reactivation regression test that exercises server close semantics plus watcher debounce/event-queue processing (no app-side fallback assumptions).
- Hardened watcher startup by seeding file-state offsets for existing JSONL files to avoid dropping the first post-start append event.

## Workstream 2: Lifecycle Reliability

Goal: active/inactive behavior is predictable and correct.

- [ ] Confirm timeout/reactivation behavior with repeated restart + live activity tests.
- [ ] Ensure passive sessions only seed as active when truly recent/active.
- [ ] Add explicit regression tests for:
  - [x] timed-out passive session reactivation on new rollout events
  - [ ] list vs detail state consistency
  - [ ] startup restore status correctness

## Workstream 3: Naming & UX Consistency

Goal: names are useful and stable across providers.

- [ ] Keep first-prompt naming as default for Claude + Codex.
- [ ] Ensure bootstrap/system payloads never become names.
- [ ] Backfill name logic for startup-seeded passive sessions where prompt exists.
- [ ] Define fallback priority in docs (`custom_name` > first prompt > project).

## Workstream 4: Observability & Diagnostics

Goal: debugging starts with server evidence, fast.

- [ ] Add a concise diagnostics endpoint/report for active sessions + source mode.
- [x] Ensure startup logs include run id + binary metadata in one consistent block.
- [ ] Add optional compact startup logs for local dev iterations.
- [ ] Keep SQL/log snippets documented for common triage flows.

## Workstream 5: MVP Verification Gate

Run this gate before calling MVP complete:

- [ ] Claude hook flow end-to-end through server only.
- [ ] Direct Codex flow end-to-end (create, prompt, tool, waiting).
- [ ] Passive Codex flow end-to-end (watcher, active/inactive transitions, naming).
- [ ] Restart recovery with no duplicate/shadow sessions.
- [ ] Session history visible and coherent after restart.
- [ ] SQL checks pass:
  - [ ] no duplicate `codex_thread_id` ownership collisions
  - [ ] expected provider/mode/status values by session type

## MVP Exit Criteria

MVP is done when all are true:

- [ ] Server is the only owner of session/message lifecycle logic and writes.
- [ ] Claude and Codex run through the same server-owned control plane model.
- [ ] Active/inactive and naming behavior are reliable across restart cycles.
- [ ] Debugging uses server logs/state first; app-local DB mutation reasoning is no longer required.

## Post-MVP Backlog (Out of Scope for This Plan)

Keep these out of MVP scope so we can finish decisively:

- Per-turn config overrides
- Context compaction UX
- Turn steer
- MCP server status UI
- Thread archive/unarchive
- Thread rollback/fork
- Code review mode
