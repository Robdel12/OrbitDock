# Server Operations and Persistence

Operations, deployment, debugging, and database guidance for the OrbitDock server.

## Deployment

The OrbitDock server is a self-contained Rust binary with embedded database migrations. Drop it on any machine — macOS, Linux, or a Raspberry Pi — and it just works.

### Quick Start

**One-liner install (macOS / Linux):**

```bash
curl -fsSL https://raw.githubusercontent.com/Robdel12/OrbitDock/main/orbitdock-server/install.sh | bash
```

**Setup wizard:**

```bash
orbitdock setup           # interactive — pick Local, Server, or Client
orbitdock setup local     # server + Claude Code on this machine
orbitdock setup server    # other devices connect to this machine
orbitdock setup client    # connect to an existing OrbitDock server
```

`setup` handles everything: initialization, hooks, background service, and network exposure.

### Deployment Topologies

**Local (developer machine):**

```bash
orbitdock setup local
```

The simplest setup. Server and Claude Code run on the same machine. This initializes the database, installs Claude Code hooks, and starts the background service.

Health check: `curl http://127.0.0.1:4000/health`

**Remote VPS / Cloud VM:**

On the server:
```bash
orbitdock setup server
```

The wizard asks how clients should reach this server (Cloudflare Tunnel, Tailscale, reverse proxy, or direct). It checks prerequisites, starts the service, and prints the URL and auth token.

On your dev machine (hooks only — no local server):
```bash
orbitdock setup client
```

Enter the server URL and auth token when prompted. The wizard tests the connection and installs hooks.

For non-interactive hook setup:
```bash
orbitdock install-hooks --server-url https://your-server.example.com:4000
```

**Home Server (Raspberry Pi / NAS):**

The install script downloads prebuilt binaries for macOS, Linux x86_64, and Linux aarch64 (Raspberry Pi 64-bit). It builds from source as a fallback on unsupported platforms (including 32-bit Pi OS), which requires the Rust toolchain.

```bash
curl -fsSL https://raw.githubusercontent.com/Robdel12/OrbitDock/main/orbitdock-server/install.sh | bash
```

### Network Exposure

**Cloudflare Tunnel (recommended):**

Zero-config HTTPS with no firewall changes or certificates.

Quick tunnel (temporary URL, no account needed):
```bash
orbitdock tunnel
# Prints: https://random-name.trycloudflare.com
```

Named tunnel (persistent URL, requires Cloudflare account):
```bash
cloudflared tunnel login
cloudflared tunnel create orbitdock
orbitdock tunnel --name orbitdock
```

**Tailscale:**

The server auto-detects Tailscale during setup and configures Tailscale Serve to expose OrbitDock over HTTPS.

```bash
orbitdock setup server   # choose Tailscale when prompted
# Prints your Tailscale HTTPS URL: https://<device>.ts.net
```

On the same machine, use `http://127.0.0.1:4000`. From another device on the tailnet, use the `https://<device>.ts.net` URL.

**Reverse Proxy (nginx / Caddy):**

Caddy (auto-TLS):
```
orbitdock.example.com {
    reverse_proxy localhost:4000
}
```

nginx:
```nginx
server {
    listen 443 ssl;
    server_name orbitdock.example.com;

    ssl_certificate /etc/letsencrypt/live/orbitdock.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/orbitdock.example.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:4000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

**Native TLS:**

If you have certificates and don't want a reverse proxy:
```bash
orbitdock start \
  --bind 0.0.0.0:4000 \
  --tls-cert /path/to/cert.pem \
  --tls-key /path/to/key.pem
```

### Connecting Clients

**macOS App:**

Settings → Servers → Add Endpoint → Enter your server URL and auth token.

**iOS App:**

Use the `pair` command to generate a connection URL:
```bash
orbitdock pair --tunnel-url https://your-tunnel.trycloudflare.com
```

**Developer Machine (hooks only):**

Point Claude Code hooks at the remote server without running a local server:
```bash
orbitdock setup client
```

Or use the lower-level command for automation:
```bash
orbitdock install-hooks --server-url https://your-server.example.com:4000
```

## Persistence and Database

### SQLite Ownership

Only the Rust server reads from and writes to SQLite directly.

The app and CLI should go through server APIs. If a workflow needs direct DB access to function, that is usually a design smell.

The server is the only writer, but direct reads are fair game for debugging.

### WAL Mode Required

All SQLite connections owned by the Rust server must use:
```sql
PRAGMA journal_mode = WAL
PRAGMA busy_timeout = 5000
```

SQLite WAL should checkpoint automatically. If it grows beyond 50MB, restart the server.

### Migrations

The Rust server owns schema changes. OrbitDock uses `refinery`, and migration files live in `orbitdock-server/migrations/` with the `VNNN__description.sql` naming convention.

When adding a migration:

1. Create `orbitdock-server/migrations/VNNN__description.sql`
2. Update the Rust persistence path if the new schema needs new reads or writes
3. Update protocol types if the new field needs to reach the app
4. Run `make rust-test`

Migrations run automatically on server startup.

### Conversation Row Persistence

Conversation row writes must follow the server's single-writer path.

Do not introduce side paths that write rows directly and race sequence assignment. This is one of the easiest ways to create subtle ordering bugs.

### Database Inspection

Examples:

```bash
sqlite3 ~/.orbitdock/orbitdock.db "SELECT id, work_status FROM sessions LIMIT 10;"
sqlite3 ~/.orbitdock/orbitdock.db "SELECT id, pending_approval_id, approval_version FROM sessions LIMIT 10;"
sqlite3 ~/.orbitdock/orbitdock.db "SELECT session_id, sequence, role FROM messages ORDER BY created_at DESC LIMIT 20;"
```

### Backup / Restore

The database is a single SQLite file:

```bash
# Backup
cp ~/.orbitdock/orbitdock.db ~/backups/orbitdock-$(date +%Y%m%d).db

# Restore
cp ~/backups/orbitdock-20240115.db ~/.orbitdock/orbitdock.db
```

## Debugging

### First Places To Look

- `~/.orbitdock/logs/server.log` for Rust server behavior
- `~/.orbitdock/logs/codex.log` for Codex integration behavior
- `~/.orbitdock/orbitdock.db` when you need to inspect persisted state directly

### Rust Server Logs

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

### Codex Logs

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

### Hook Transport Checks

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

### Memory Profiling (macOS)

Use the capture script when the app looks memory-heavy:

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

### Prometheus Metrics

The `/metrics` endpoint exposes Prometheus-compatible metrics:

```bash
curl http://localhost:4000/metrics
```

If auth is enabled (recommended), include the Authorization header.

Available metrics:
- `orbitdock_uptime_seconds` — server uptime
- `orbitdock_websocket_connections` — active WebSocket connections
- `orbitdock_total_sessions` / `orbitdock_active_sessions`
- `orbitdock_sessions_by_provider{provider="claude|codex"}`
- `orbitdock_sessions_by_status{status="working|permission|..."}`
- `orbitdock_db_size_bytes` / `orbitdock_db_wal_size_bytes`

## Security

### Auth Tokens

`orbitdock init` automatically provisions a local auth token. Auth is enforced on all routes except `/health` once a token exists.

```bash
# Retrieve the local token (decrypted from hook-forward.json)
orbitdock auth local-token

# Generate additional tokens for remote clients
orbitdock generate-token
```

The token is required in:
- `Authorization: Bearer <token>` header for HTTP requests
- `Authorization: Bearer <token>` header for WebSocket handshake requests

Unauthenticated endpoints: `/health`

### Encryption at Rest

Config values (like API keys) are encrypted with AES-256-GCM.

The encryption key is auto-generated at `~/.orbitdock/encryption.key` on first run. Back it up — if lost, encrypted config values become unrecoverable.

### Firewall

Only expose port 4000 (or your chosen port). The server doesn't need outbound access except for:
- AI provider APIs (OpenAI, Anthropic) when running direct sessions
- Cloudflare when using tunnels

## Upgrading

Re-run the install script to update the binary:

```bash
curl -fsSL https://raw.githubusercontent.com/Robdel12/OrbitDock/main/orbitdock-server/install.sh | bash
# Migrations run automatically on startup
```

The install script only updates the binary — it won't re-prompt about hooks or services.

## Troubleshooting

### `doctor` command

Run diagnostics:

```bash
orbitdock doctor
```

Checks: data directory, database, encryption key, Claude CLI, auth token, hook transport config, hooks in settings.json, WAL size, port availability, health endpoint, disk space.

### Common Issues

**"Hook transport config not found"**
Run `orbitdock install-hooks` to generate `~/.orbitdock/hook-forward.json`.

**"Connection refused"**
Server not running. Check `orbitdock status` and start with `orbitdock start`.

**"Unauthorized"**
Auth token mismatch. Issue a new token with `orbitdock generate-token`, then rerun `orbitdock install-hooks`.

**"Events not arriving"**
1. Check hook transport config: `ls -la ~/.orbitdock/hook-forward.json`
2. Check hooks in settings: `cat ~/.claude/settings.json | jq '.hooks'`
3. Test manually: `echo '{"session_id":"test","cwd":"/tmp"}' | orbitdock hook-forward claude_status_event`

**Large WAL file**
SQLite WAL should checkpoint automatically. If it grows beyond 50MB, restart the server. Check with `orbitdock doctor`.
