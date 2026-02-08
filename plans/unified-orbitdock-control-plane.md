# Unified OrbitDock Control Plane

> OrbitDock architecture migration plan.
> Goal: `orbitdock-server` becomes the source of truth for business logic and persistence.

## Vision

OrbitDock runs as a client/server system:

```
SwiftUI app (view client) <-> orbitdock-server (business logic + persistence)
```

Rules:
- Server owns session/message lifecycle, state transitions, counters, status, and DB writes.
- App renders server state and sends commands.
- App must not be a second business-logic engine.
- SQLite is an implementation detail behind server APIs/events.

## Scope Strategy

We are migrating in phases:
- Phase 1 (now): Codex paths are server-first and hardened.
- Phase 2: Claude hooks routed through server.
- Phase 3: Remove remaining app-side DB business logic.

This keeps Claude stable while codifying the target architecture.

---

## Current Status (as of 2026-02-07)

### Completed foundation
- Rust server manages direct Codex sessions.
- Rust server rollout watcher handles Codex CLI transcript/session lifecycle.
- Server WebSocket protocol supports session list/snapshot/delta + actions.
- MCP debug bridge can control direct Codex sessions end-to-end.

### Known architecture debt
- App still reads/writes some session/message state directly from SQLite.
- OrbitDockCore Claude hook CLI still writes DB directly.
- Mixed write paths increase ambiguity during debugging/restart.

---

## Non-Negotiable Ownership Contract

### Server-owned (target and going forward)
- Session creation, updates, ending, resuming.
- Message append/update lifecycle.
- Work status/attention reason/state transitions.
- Prompt/tool counters and first-prompt capture.
- Session naming and metadata.
- Persistence writes for session/message tables.

### App-owned
- Rendering state.
- Local UI-only state (panel layout, sorting, filters, toasts, window state).
- User actions translated into server commands.

### Temporary exceptions (must be removed)
- App-side DB fallback reads for Codex history.
- OrbitDockCore direct DB writes for Claude hooks.

---

## Migration Plan

## Phase 1: Codex Server-First Hardening

### 1.1 Eliminate Codex split-brain paths
- [x] Rust rollout watcher replaced Swift rollout watcher.
- [x] Prevent duplicate shadow sessions for direct thread IDs.
- [x] Persistence guardrails: rollout updates no-op for direct-thread-owned sessions.

### 1.2 Stabilize app behavior with current boundaries
- [ ] Ensure ended/direct session history is delivered via server snapshot/history path (not app DB fallback).
- [ ] Remove app-side Codex subscription attempts when session is not server-managed.
- [ ] Add tolerant timestamp decoding in any unavoidable fallback reader until fully removed.

### 1.3 Codex E2E verification gate
- [ ] Create direct session, send 3 turns, verify live streaming and tool events.
- [ ] Restart app, verify session restores with correct provider/mode.
- [ ] Resume ended direct session, verify resumed lifecycle and no duplicate sessions.
- [ ] Run rollout-watched CLI Codex session, verify correct provider/state/counters.
- [ ] Verify no duplicate session rows for same thread id.

---

## Phase 2: Claude Hook Routing Through Server

### 2.1 Protocol + transport
- [ ] Add server message types for Claude hook events: session-start/end, status, tool, subagent.
- [ ] Add CLI transport mode to forward hook payloads to server.
- [ ] Keep direct-SQL fallback mode behind explicit feature flag only.

### 2.2 Server handling
- [ ] Map Claude hook payloads into unified server session/message lifecycle.
- [ ] Persist via `PersistCommand` only.
- [ ] Broadcast unified session/message deltas to app.

### 2.3 Verification
- [ ] Claude hook flow works end-to-end with server transport enabled.
- [ ] App behavior unchanged for Claude users.
- [ ] Disable fallback and verify no regressions in normal workflow.

---

## Phase 3: Remove App DB Business Logic for Sessions/Messages

### 3.1 App read-path cleanup
- [ ] Replace direct DB transcript/session reads in Codex flows with server-backed state.
- [ ] Add server query endpoints as needed for historical message retrieval.
- [ ] Remove Codex dependency on `MessageStore` for lifecycle data.

### 3.2 App write-path cleanup
- [ ] Remove app-side Codex session/message mutation calls.
- [ ] Restrict app DB writes to UI-local/productivity features not owned by session engine.

### 3.3 Contract enforcement
- [ ] Add lint/checklist rule: no new session/message business logic in app layer.
- [ ] Add architecture docs section: “server owns session engine.”

---

## Phase 4: Operational Confidence

- [ ] Startup log includes binary path, mtime, and run id.
- [ ] Optional startup log truncation in debug mode.
- [ ] Health-check warmup uses concise retry logs.
- [ ] Add diagnostics endpoint/report for active sessions + source mode.
- [ ] Add integration smoke test script for local dev verification.

---

## Codex Integration Smoke Checklist (Run Every Iteration)

1. Start OrbitDock app.
2. Create new direct Codex session.
3. Send one user message from UI.
4. Send one message via MCP debug bridge to same session.
5. Confirm conversation shows both turns and session returns to waiting.
6. Restart app.
7. Re-open same session and verify history is visible.
8. Ensure provider/mode is correct and no shadow duplicate appears.
9. Query DB for session id and thread id uniqueness.

SQL checks:
- `SELECT id, provider, codex_integration_mode, status, work_status FROM sessions ORDER BY datetime(last_activity_at) DESC LIMIT 20;`
- `SELECT codex_thread_id, COUNT(*) FROM sessions WHERE codex_thread_id IS NOT NULL GROUP BY codex_thread_id HAVING COUNT(*) > 1;`

---

## Exit Criteria

We consider this migration complete when:
- Session/message business logic runs only in `orbitdock-server`.
- App is a thin reactive client for those domains.
- Claude and Codex both flow through the same server-owned write path.
- Debugging a session requires server logs/state first, not app-local DB mutation reasoning.

---

## Notes

- Codex remains the implementation proving ground while we preserve Claude stability.
- If a short-term patch is needed in app code to avoid crashes, apply it, but track it as migration debt and remove it once server path is complete.
