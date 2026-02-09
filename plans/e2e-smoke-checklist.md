# OrbitDock E2E Smoke Checklist (Current Scope)

Use this after rebuild/rerun to validate real user outcomes across all implemented modes.

## Preflight

- [ ] App starts, server healthy, no startup errors in `~/.orbitdock/logs/server.log` and `~/.orbitdock/logs/app.log`
- [ ] `Active Sessions` loads without runaway growth
- [ ] `Session History` renders without crashes

## Mode 1: Codex Direct (MCP-Controllable)

- [ ] Create a new direct Codex session from OrbitDock UI
- [ ] MCP `list_sessions` shows it as `provider=codex`, `controllable=yes`, `waiting`
- [ ] Send a normal message (no tools): session goes `working -> waiting`, assistant response appears
- [ ] Send a command that requires approval: session goes `permission`, approval UI/card appears
- [ ] Approve once: command executes, pending approval clears, session returns to `working/waiting` (not stuck)
- [ ] Deny once: command does not execute, pending approval clears, session returns to `waiting` (not stuck)
- [ ] Interrupt an active turn: session exits `working` and remains usable
- [ ] Rebuild/rerun app: same direct session restores with messages and correct provider/mode

## Mode 2: Codex CLI Passive (Rollout-Watched)

- [ ] Start/continue a Codex CLI session in terminal (outside OrbitDock)
- [ ] Session appears in OrbitDock with `provider=codex`, passive mode, correct project path
- [ ] New terminal activity updates work state in UI (`working`, `permission`, `waiting` as applicable)
- [ ] No direct-control actions are exposed for passive session (MCP controllable=no)
- [ ] Rebuild/rerun app: active CLI session still appears (not missing), no duplicate rows

## Mode 3: Claude CLI Passive

- [ ] Start/continue a Claude CLI session
- [ ] Session appears with `provider=claude`, correct project path
- [ ] Transcript/messages render in conversation view
- [ ] Rebuild/rerun app: Claude passive session remains visible and consistent

## Cross-Mode Invariants

- [ ] No provider flips (direct Codex never reappears as Claude/passive)
- [ ] No duplicate/shadow rows for same thread/session identity
- [ ] Active vs ended separation is correct (`Active Sessions` vs `Session History`)
- [ ] Approval history entries appear with correct final decision labels (not stuck at `pending`)
- [ ] Token/status badges remain sane after resume/reconnect

## Optional DB Sanity Queries

```bash
sqlite3 ~/.orbitdock/orbitdock.db "
SELECT id, provider, codex_integration_mode, status, work_status, project_path
FROM sessions
ORDER BY datetime(last_activity_at) DESC
LIMIT 30;"
```

```bash
sqlite3 ~/.orbitdock/orbitdock.db "
SELECT provider, codex_integration_mode, status, work_status, COUNT(*)
FROM sessions
GROUP BY 1,2,3,4
ORDER BY COUNT(*) DESC;"
```

## Exit Criteria

- [ ] All three modes pass
- [ ] No stuck `working`/`pending` states after approval decisions
- [ ] No missing active CLI sessions after app restart
- [ ] No duplicate session explosions

