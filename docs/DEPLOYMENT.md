# Deploying OrbitDock Server

The OrbitDock server is a self-contained Rust binary with embedded database migrations. Drop it on any machine — macOS, Linux, or a Raspberry Pi — and it just works.

## Quick Start

### One-liner install (macOS / Linux)

```bash
curl -fsSL https://raw.githubusercontent.com/Robdel12/OrbitDock/main/orbitdock-server/install.sh | bash
```

### Setup wizard

```bash
orbitdock setup           # interactive — pick Local, Server, or Client
orbitdock setup local     # server + Claude Code on this machine
orbitdock setup server    # other devices connect to this machine
orbitdock setup client    # connect to an existing OrbitDock server
```

`setup` handles everything: initialization, hooks, background service, and network exposure.

## Deployment Topologies

### Local (developer machine)

The simplest setup. Server and Claude Code run on the same machine.

```bash
orbitdock setup local
```

This initializes the database, installs Claude Code hooks, and starts the background service.
Health check: `curl http://127.0.0.1:4000/health`

### Remote VPS / Cloud VM

Run the server on a VPS, connect from your dev machine.

**On the server:**

```bash
orbitdock setup server
```

The wizard asks how clients should reach this server (Cloudflare Tunnel, Tailscale, reverse proxy, or direct).
It checks prerequisites, starts the service, and prints the URL and auth token.

**On your dev machine** (hooks only — no local server):

```bash
orbitdock setup client
```

Enter the server URL and auth token when prompted. The wizard tests the connection and installs hooks.

For non-interactive hook setup, you can still use the lower-level command:

```bash
orbitdock install-hooks \
  --server-url https://your-server.example.com:4000
```

### Home Server (Raspberry Pi / NAS)

The install script downloads a prebuilt binary for macOS, Linux x86_64, and Linux aarch64 (Raspberry Pi 64-bit). It builds from source as a fallback on unsupported platforms (including 32-bit Pi OS), which requires the [Rust toolchain](https://rustup.rs):

```bash
curl -fsSL https://raw.githubusercontent.com/Robdel12/OrbitDock/main/orbitdock-server/install.sh | bash
```

### Building Release Assets Locally (Maintainers)

From the repo root, generate release zips into `dist/`.
Linux targets auto-use Docker when the host is not matching native Linux (for example on macOS), so install Docker Desktop + Buildx first.

```bash
# Quick local validation loop (faster profile + container smoke tests)
make rust-release-linux-validate

# macOS arm64
make rust-release-darwin

# Both Linux release artifacts
make rust-release-linux-all

# Validate both Linux release zips in matching containers
make rust-release-linux-test

# Linux x86_64 (full release profile)
make rust-release-linux-x86_64

# Linux aarch64 (Raspberry Pi 64-bit, low-memory release profile by default)
make rust-release-linux-aarch64

# Full release profile override (requires more Docker memory on arm64 emulation)
make rust-release-linux-aarch64 LINUX_AARCH64_PROFILE_PRESET=release
```

Each command writes a `.zip` plus `.sha256` file in `dist/`. Attach those files to the GitHub release.
The `make rust-release-*` targets run `web-build` first, so the packaged binary embeds the current `orbitdock-web/dist` output.
Set `ORBITDOCK_LINUX_BUILD_MODE=native|docker|auto` to override Linux build mode (`auto` is default).
`make rust-release-linux-aarch64` defaults to `release-lowmem` (thin LTO, codegen-units=8) plus `LINUX_AARCH64_DOCKER_JOBS=1` to avoid Docker OOM on local macOS arm64 emulation.
Set `ORBITDOCK_LINUX_PROFILE_PRESET=smoke` for faster local validation builds (disables release LTO and uses more codegen units).
Docker Linux builds now use persistent local Buildx cache export/import by default.
Use `ORBITDOCK_LINUX_DOCKER_CACHE_MODE=none` to disable explicit local cache handling.
Use `ORBITDOCK_LINUX_DOCKER_CARGO_BUILD_JOBS=<n>` to cap Docker cargo parallelism (useful for arm64 emulation memory pressure).

### App Releases

macOS and iOS app releases are currently manual.

That is intentional. The native client is being reshaped around the sandboxed universal-client model, and we are not treating CI as the source of truth for app signing, packaging, or distribution right now.

If you want to ship the app:

1. Open the project in Xcode
2. Archive the app you want to ship
3. Sign, notarize, or upload it through your normal Apple tooling flow
4. Publish any app artifacts manually

There is no Sparkle feed, no appcast generation step, and no automated macOS app packaging workflow in this repo anymore.

### Server Release Automation

Server release automation stays in place.

Use the GitHub **Release** workflow, or trigger it locally:

```bash
make release CHANNEL=stable BUMP=patch
```

Inputs:

- `channel`: `stable`, `beta`, or `nightly`
- `version_mode`: `auto` (default SemVer bump) or `explicit`
- `bump`: `patch|minor|major` (used when `version_mode=auto`)
- `build_server_assets`: set to `false` only if you want metadata/notes without binaries
- `publish_release`: set to `false` if you want CI to prepare the release in draft form

CI now handles:

- release metadata
- release notes drafting
- darwin arm64 server packaging
- linux x86_64 server packaging
- linux aarch64 server packaging
- GitHub release publishing for server artifacts

### Nightly Automation

`.github/workflows/nightly.yml` now runs the same server-focused release workflow with `channel=nightly`. It still runs daily at 06:00 UTC, and you can dispatch it manually if you want an extra nightly.

### Cloud Providers

Deploy the binary directly on any Linux VM. The server is stateless except for SQLite — use a persistent disk for the data directory.

## Network Exposure

### Cloudflare Tunnel (recommended)

Zero-config HTTPS with no firewall changes or certificates.

**Quick tunnel** (temporary URL, no account needed):

```bash
orbitdock tunnel
# Prints: https://random-name.trycloudflare.com
```

**Named tunnel** (persistent URL, requires Cloudflare account):

```bash
cloudflared tunnel login
cloudflared tunnel create orbitdock
orbitdock tunnel --name orbitdock
```

### Tailscale

The server auto-detects Tailscale during setup.

```bash
orbitdock setup server   # choose Tailscale when prompted
# Prints your Tailscale IP: http://100.x.y.z:4000
# Auth token is shown during setup
```

`0.0.0.0:4000` is the server's bind address, not a client destination.
On the same machine, use `http://127.0.0.1:4000`.
From another device, use the machine's real LAN, Tailscale, tunnel, or public HTTPS address.

### Reverse Proxy (nginx / Caddy)

**Caddy** (auto-TLS):

```
orbitdock.example.com {
    reverse_proxy localhost:4000
}
```

**nginx:**

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

### Native TLS

If you have certificates and don't want a reverse proxy:

```bash
orbitdock start \
  --bind 0.0.0.0:4000 \
  --tls-cert /path/to/cert.pem \
  --tls-key /path/to/key.pem
```

Clients still should not use `http://0.0.0.0:4000`.
Use `https://127.0.0.1:4000` locally only if you explicitly trust the cert, or preferably the host/IP name the certificate was issued for.

## Security

### Auth Tokens

`orbitdock init` automatically provisions a local auth token — the hash is stored in the database and the plaintext is encrypted in `hook-forward.json`. Auth is enforced on all routes except `/health` once a token exists.

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

CORS is disabled by default. If you need browser access, explicitly set
`ORBITDOCK_CORS_ALLOWED_ORIGINS` (comma-separated origins).

### Encryption at Rest

Config values (like API keys) are encrypted with AES-256-GCM.

The encryption key is auto-generated at `~/.orbitdock/encryption.key` on first run. Back it up — if lost, encrypted config values become unrecoverable.

### Firewall

Only expose port 4000 (or your chosen port). The server doesn't need outbound access except for:
- AI provider APIs (OpenAI, Anthropic) when running direct sessions
- Cloudflare when using tunnels

## Connecting Clients

### macOS App

Settings → Servers → Add Endpoint → Enter your server URL and auth token.
If auth is enabled, the token is entered separately here. Pairing URLs and QR codes never embed it.

### iOS App

Use the `pair` command to generate a QR code:

```bash
orbitdock pair --tunnel-url https://your-tunnel.trycloudflare.com
```

Scan the QR code from the iOS app's server settings.
If auth is enabled, enter the token separately after scanning. The QR code only contains the server URL.

### Developer Machine (hooks only)

Point Claude Code hooks at the remote server without running a local server:

```bash
orbitdock setup client
# Enter server URL and auth token when prompted
```

Or use the lower-level command for automation:

```bash
orbitdock install-hooks \
  --server-url https://your-server.example.com:4000
```

You will be prompted for the token. For automation, use `ORBITDOCK_AUTH_TOKEN` or `--auth-token`.

## Operations

### Prometheus Metrics

The `/metrics` endpoint exposes Prometheus-compatible metrics:

```bash
# If auth is enabled (recommended), include Authorization header:
# curl -H "Authorization: Bearer <token>" http://localhost:4000/metrics
curl http://localhost:4000/metrics
```

Available metrics:
- `orbitdock_uptime_seconds` — server uptime
- `orbitdock_websocket_connections` — active WebSocket connections
- `orbitdock_total_sessions` / `orbitdock_active_sessions`
- `orbitdock_sessions_by_provider{provider="claude|codex"}`
- `orbitdock_sessions_by_status{status="working|permission|..."}`
- `orbitdock_db_size_bytes` / `orbitdock_db_wal_size_bytes`

### Logging

Structured JSON logs at `~/.orbitdock/logs/server.log`:

```bash
tail -f ~/.orbitdock/logs/server.log | jq .
tail -f ~/.orbitdock/logs/server.log | jq 'select(.level == "ERROR")'
```

Control with environment variables:
- `ORBITDOCK_SERVER_LOG_FILTER=debug` — verbose logging
- `ORBITDOCK_SERVER_LOG_FORMAT=pretty` — human-readable format
- `ORBITDOCK_TRUNCATE_SERVER_LOG_ON_START=1` — fresh log each boot

### Backup / Restore

The database is a single SQLite file:

```bash
# Backup
cp ~/.orbitdock/orbitdock.db ~/backups/orbitdock-$(date +%Y%m%d).db

# Restore
cp ~/backups/orbitdock-20240115.db ~/.orbitdock/orbitdock.db
```

### Upgrading

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
Run `orbitdock install-hooks` to generate `~/.orbitdock/hook-forward.json` (includes encrypted token when provided).

**"Connection refused"**
Server not running. Check `orbitdock status` and start with `orbitdock start`.

**"Unauthorized"**
Auth token mismatch. Issue a new token with `orbitdock generate-token`, then rerun `orbitdock install-hooks` and enter the new token.

**"Events not arriving"**
1. Check hook transport config exists: `ls -la ~/.orbitdock/hook-forward.json`
2. Check hooks in settings: `cat ~/.claude/settings.json | jq '.hooks'`
3. Test manually: `echo '{"session_id":"test","cwd":"/tmp","hook_event_name":"Stop"}' | orbitdock hook-forward claude_status_event`

**Large WAL file**
SQLite WAL should checkpoint automatically. If it grows beyond 50MB, restart the server. Check with `orbitdock doctor`.
