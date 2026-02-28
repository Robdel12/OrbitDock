# OrbitDock

Mission control for AI coding agents. Manage Claude Code and Codex sessions from your Mac or
your phone — create sessions, review diffs, approve tools, and steer agents from anywhere.

![macOS](https://img.shields.io/badge/macOS-15.0+-blue)
![iOS](https://img.shields.io/badge/iOS-26.0+-blue)
![Swift](https://img.shields.io/badge/Swift-6.0-orange)
![Rust](https://img.shields.io/badge/Rust-stable-red)
![License](https://img.shields.io/badge/license-MIT-green)

https://github.com/user-attachments/assets/58be4f6e-55f9-43fe-9336-d3db99c4471c

## Why

I don't write code anymore (pretty much) -- agents do. My job is review, management, and provide guidance at
the right time. But with multiple repos and a bunch of agents running across all of them, keeping
track of it all was chaos. OrbitDock is how I'm trying to wrangle that.

A Rust server sits at the center. It runs both Claude Code and Codex sessions directly, and
picks up existing CLI sessions via hooks. Run a server on your laptop, your work machine, a VPS,
wherever your agents are. The macOS and iOS apps connect to all of them at once, so you get one
unified view no matter where your sessions are running or what device you're on.

## What You Get

- **Run agents from anywhere** — Create and control Claude and Codex sessions from Mac or iOS
- **Live monitoring** — Every session across every project, updating in real time
- **Code review** — Magit-style diffs with inline comments that steer the agent
- **Approval triage** — Diff previews, risk cues, keyboard shortcuts (y/n/!/N)
- **Direct control** — Send messages, approve tools, interrupt, run shell commands
- **Usage tracking** — Rate limit monitoring for Claude and Codex
- **Multi-server** — Connect to local, remote, and cloud endpoints at once

See [FEATURES.md](docs/FEATURES.md) for the full list.

## Quickstart (No Bullshit)

If you want this running locally in a few minutes, do exactly this:

### 1. Install the server

```bash
curl -fsSL https://raw.githubusercontent.com/Robdel12/OrbitDock/main/orbitdock-server/install.sh | bash
```

The installer sets up the binary, data directory, database, Claude hooks, and background service.

### 2. Verify it actually started

```bash
orbitdock-server status
curl http://127.0.0.1:4000/health
orbitdock-server doctor
```

You should see healthy output from all three.

### 3. Open the app

Download from [Releases](https://github.com/Robdel12/OrbitDock/releases), or build from source:

```bash
git clone https://github.com/Robdel12/OrbitDock.git
cd OrbitDock
make build
open OrbitDock/OrbitDock.xcodeproj   # Cmd+R
```

The app auto-connects to the local server endpoint.

### 4. Authenticate the provider you want to run

- **Codex direct sessions**: open `Settings` → `CODEX CLI`, then sign in with ChatGPT (or use API key auth mode).
- **Claude Code monitoring/control**: install Claude Code and log in; if you skipped hook install, run `orbitdock-server install-hooks`.

### 5. Smoke test

- In OrbitDock, click `New Codex Session`, pick any local repo, and send a prompt.
- Or start a Claude Code session in your terminal and confirm it appears in OrbitDock.

If a session does not appear, run `orbitdock-server doctor` and check `~/.orbitdock/logs/server.log`.

### Remote server

Running on a VPS, Raspberry Pi, or another machine:

```bash
orbitdock-server setup --remote
```

See [DEPLOYMENT.md](docs/DEPLOYMENT.md) for Cloudflare tunnels, TLS, Docker, and more.

## Requirements

- macOS 15.0+ (iOS 26.0+ for mobile)
- **Codex** is built in — the server embeds codex-core; authenticate with ChatGPT sign-in or API key mode
- **Claude Code** requires a separate install and active login — OrbitDock monitors it via hooks
- Xcode 16+ and Rust stable toolchain if building from source

## Documentation

- [FEATURES.md](docs/FEATURES.md) — Full feature list with keyboard shortcuts
- [DEPLOYMENT.md](docs/DEPLOYMENT.md) — Server deployment guide (remote, TLS, tunnels)
- [CONTRIBUTING.md](docs/CONTRIBUTING.md) — Development setup and architecture
- [orbitdock-server/README.md](orbitdock-server/README.md) — Server CLI reference

## License

[MIT](LICENSE)
