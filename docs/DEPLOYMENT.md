# Deploying OrbitDock Server

The OrbitDock server is a self-contained Rust binary with embedded database migrations. Drop it on any machine — macOS, Linux, or a Raspberry Pi — and it just works.

## Quick Start

### One-liner install (macOS / Linux)

```bash
curl -fsSL https://raw.githubusercontent.com/Robdel12/OrbitDock/main/orbitdock-server/install.sh | bash
```

### Setup wizard

```bash
orbitdock setup --local    # localhost only
orbitdock remote-setup     # secure remote exposure onboarding
```

`setup` is for local machine bootstrap. Use `remote-setup` when you want to expose an existing install
securely to other machines.

## Deployment Topologies

### Local (developer machine)

The simplest setup. Server and Claude Code run on the same machine.

```bash
orbitdock setup --local
# or manually:
orbitdock init
orbitdock install-hooks
orbitdock install-service --enable
```

Health check: `curl http://127.0.0.1:4000/health`

### Remote VPS / Cloud VM

Run the server on a VPS, connect from your dev machine.

**On the server:**

```bash
orbitdock remote-setup
```

**On your dev machine** (hooks only — no local server):

```bash
orbitdock install-hooks \
  --server-url https://your-server.example.com:4000
```

`remote-setup` prints the exact client URL and auth token instructions after it configures the server side.
`install-hooks` will prompt for the token and store it encrypted in `~/.orbitdock/hook-forward.json`.
For non-interactive setup, pass `--auth-token <token>` or set `ORBITDOCK_AUTH_TOKEN`.

Or use the install script:

```bash
curl -fsSL https://raw.githubusercontent.com/Robdel12/OrbitDock/main/orbitdock-server/install.sh | bash -s -- --server-url https://your-server.example.com:4000
```

The installer forwards `--auth-token` / `ORBITDOCK_AUTH_TOKEN` when you need a non-interactive remote install.
The simplest non-interactive flow is:

```bash
export ORBITDOCK_AUTH_TOKEN=<token>
curl -fsSL https://raw.githubusercontent.com/Robdel12/OrbitDock/main/orbitdock-server/install.sh | bash -s -- --server-url https://your-server.example.com:4000
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

### macOS App Releases with Sparkle

OrbitDock uses Sparkle for macOS app updates with three update channels:

| Channel | Feed URL | Publishing |
|---------|----------|------------|
| **Stable** | `releases/latest/download/appcast.xml` | Manual (maintainer) |
| **Beta** | `releases/latest/download/appcast-beta.xml` | Manual (maintainer) |
| **Nightly** | `releases/download/nightly/appcast-nightly.xml` | Automated (CI) |

Users choose their update channel in **Preferences → Workspace → Updates**. The default is Stable. Each channel has its own appcast so stable users never see non-stable builds.

#### Stable / Beta releases (manual)

1. Archive and notarize the macOS app locally:

```bash
VERSION=0.4.0 \
CHANNEL=stable \
SPARKLE_PUBLIC_ED_KEY="<public key>" \
MACOS_DEVELOPMENT_TEAM="<team id>" \
APPLE_NOTARY_KEY_ID="<key id>" \
APPLE_NOTARY_ISSUER_ID="<issuer id>" \
APPLE_NOTARY_PRIVATE_KEY="$(cat AuthKey_ABC123XYZ.p8)" \
./scripts/archive-macos-app-release.sh
```

Set `CHANNEL=beta` for beta releases. This compiles the matching feed URL into the binary.

2. Upload `dist/OrbitDock-<version>.zip` and `dist/OrbitDock-<version>.zip.sha256` to the matching GitHub Release.
3. Generate the appcast locally:

```bash
SITE_DIR=/tmp/orbitdock-release-assets \
RELEASE_TAG=v0.4.0 \
CHANNEL=stable \
SPARKLE_PRIVATE_ED_KEY="<private key>" \
./scripts/generate-sparkle-appcast.sh
```

Set `CHANNEL=beta` to generate `appcast-beta.xml` instead.

4. Upload the generated appcast to that same GitHub Release.

#### Nightly releases (automated)

The `.github/workflows/nightly.yml` workflow runs daily at 06:00 UTC (and on manual dispatch). It:

1. Computes a nightly version like `0.4.0-nightly.20260324`
2. Archives, notarizes, and signs the macOS app
3. Generates `appcast-nightly.xml`
4. Publishes everything to a rolling `nightly` GitHub prerelease

Required repository secrets for the nightly workflow:

- `SPARKLE_PUBLIC_ED_KEY` — compiled into the app
- `SPARKLE_PRIVATE_ED_KEY` — signs the appcast
- `MACOS_DEVELOPMENT_TEAM` — Apple team ID for code signing
- `APPLE_NOTARY_KEY_ID` — App Store Connect API key ID
- `APPLE_NOTARY_ISSUER_ID` — App Store Connect issuer ID
- `APPLE_NOTARY_PRIVATE_KEY` — App Store Connect API private key (`.p8` contents)

#### Sparkle key notes

- `SPARKLE_PUBLIC_ED_KEY` is compiled into the app and used to verify updates.
- `SPARKLE_PRIVATE_ED_KEY` is used to sign appcast files.
- Generate the keypair with Sparkle’s `generate_keys` tool. Export the private key for local publishing with `generate_keys -x private_key.txt`.
- All channels share the same Sparkle keypair — the signing is per-appcast, not per-channel.

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

The server auto-detects Tailscale during `init` and prints your Tailscale IP. `init` also provisions an auth token automatically.

```bash
orbitdock init
orbitdock start --bind 0.0.0.0:4000
# Access via your Tailscale IP: http://100.x.y.z:4000
# Auth token: orbitdock auth local-token
```

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
- `orbitdock_spool_queue_depth`

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

```bash
curl -fsSL https://raw.githubusercontent.com/Robdel12/OrbitDock/main/orbitdock-server/install.sh | bash
# Migrations run automatically on startup
```

## Troubleshooting

### `doctor` command

Run diagnostics:

```bash
orbitdock doctor
```

Checks: data directory, database, encryption key, Claude CLI, auth token, hook transport config, hooks in settings.json, spool queue, WAL size, port availability, health endpoint, disk space.

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
3. Check spool: `ls ~/.orbitdock/spool/` (queued = server temporarily unreachable)
4. Test manually: `echo '{"session_id":"test","cwd":"/tmp","hook_event_name":"Stop"}' | orbitdock hook-forward claude_status_event`

**Large WAL file**
SQLite WAL should checkpoint automatically. If it grows beyond 50MB, restart the server. Check with `orbitdock doctor`.
