# Debugging OrbitDock

Use this doc when something is broken and you need the fastest path to logs, filters, and sanity checks.

## First Places To Look

- `~/.orbitdock/logs/server.log` for Rust server behavior
- `~/.orbitdock/logs/codex.log` for Codex integration behavior
- `~/.orbitdock/orbitdock.db` when you need to inspect persisted state directly

## Rust Server Logs

The Rust server writes structured JSON logs to disk. Interactive dev runs also mirror them into the dev console by default.

Basic commands:

```bash
tail -f ~/.orbitdock/logs/server.log | jq .
tail -f ~/.orbitdock/logs/server.log | jq 'select(.level == "ERROR")'
tail -f ~/.orbitdock/logs/server.log | jq 'select(.component == "websocket")'
tail -f ~/.orbitdock/logs/server.log | jq 'select(.event == "session.resume.connector_failed")'
tail -f ~/.orbitdock/logs/server.log | jq 'select(.session_id == "your-session-id")'
tail -f ~/.orbitdock/logs/server.log | jq 'select(.request_id == "your-request-id")'
```

Useful log controls:

```bash
make rust-run-debug
RUST_LOG=debug make rust-run
```

Environment variables:

- `ORBITDOCK_SERVER_LOG_FILTER`
- `ORBITDOCK_SERVER_LOG_FORMAT=json|pretty`
- `ORBITDOCK_TRUNCATE_SERVER_LOG_ON_START=1`
- `ORBITDOCK_DEV_CONSOLE=0`

Stable fields worth filtering on:

- `event`
- `component`
- `session_id`
- `request_id`
- `connection_id`
- `error`

## Codex Logs

Codex integration logs are also structured JSON.

Basic commands:

```bash
tail -f ~/.orbitdock/logs/codex.log | jq .
tail -f ~/.orbitdock/logs/codex.log | jq 'select(.level == "error")'
tail -f ~/.orbitdock/logs/codex.log | jq 'select(.category == "decode")'
tail -f ~/.orbitdock/logs/codex.log | jq 'select(.category == "event")'
tail -f ~/.orbitdock/logs/codex.log | jq 'select(.sessionId == "codex-direct-abc123")'
tail -f ~/.orbitdock/logs/codex.log | jq 'select(.message | contains("item/"))'
```

Common categories:

- `event`
- `connection`
- `message`
- `decode`
- `session`

If decode fails, inspect the raw payload in the `decode` category first. That's usually the fastest way to fix mismatched struct definitions.

## Database Inspection

The server is the only writer, but direct reads are fair game for debugging.

Examples:

```bash
sqlite3 ~/.orbitdock/orbitdock.db "SELECT id, work_status FROM sessions LIMIT 10;"
sqlite3 ~/.orbitdock/orbitdock.db "SELECT id, pending_approval_id, approval_version FROM sessions LIMIT 10;"
sqlite3 ~/.orbitdock/orbitdock.db "SELECT session_id, sequence, role FROM messages ORDER BY created_at DESC LIMIT 20;"
```

## Hook Transport Checks

With the server running, send a test hook event directly:

```bash
echo '{"session_id":"test","cwd":"/tmp","model":"claude-opus-4-6","source":"startup"}' \
  | orbitdock hook-forward claude_session_start
```

Or hit the server without the helper:

```bash
curl -s -X POST -H "Content-Type: application/json" \
  -d '{"type":"claude_session_start","session_id":"test","cwd":"/tmp"}' \
  http://127.0.0.1:4000/api/hook
```

## Memory Profiling (macOS)

Use the capture script when the app looks memory-heavy and you need reproducible artifacts:

```bash
scripts/capture_memory_profile.sh
```

Target a specific process or shorten capture windows:

```bash
scripts/capture_memory_profile.sh \
  --pid 9718 \
  --sample-seconds 5 \
  --trace-seconds 10 \
  --out-dir /tmp/orbitdock-profile
```

The script writes a timestamped output directory with:

- `ps.txt`
- `vmmap-summary.txt`
- `sample.txt`
- `allocations.trace` and `xctrace-toc.xml` when trace capture is enabled
- `capture-summary.txt`

If `vmmap`, `sample`, or `xctrace` fails with permission errors, rerun with elevated permissions.

## Good Places To Read Code

When logs point at a specific subsystem, these are the usual next stops:

- `orbitdock-server/crates/cli/src/main.rs`
- `orbitdock-server/crates/server/src/app/mod.rs`
- `orbitdock-server/crates/server/src/transport/http/`
- `orbitdock-server/crates/server/src/transport/websocket/`
- `orbitdock-server/crates/server/src/infrastructure/persistence/`
- `orbitdock-server/crates/server/src/connectors/codex_session.rs`

## If The Bug Looks Like A Contract Bug

Check these docs next:

- [data-flow.md](data-flow.md)
- [client-networking.md](client-networking.md)
- [SWIFT_CLIENT_ARCHITECTURE.md](SWIFT_CLIENT_ARCHITECTURE.md)
