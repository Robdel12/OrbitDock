# OrbitDock

Mission control for AI coding agents. One dashboard for all your Claude Code and Codex sessions — live status, conversations, code review, approvals, and usage tracking.

![macOS](https://img.shields.io/badge/macOS-15.0+-blue)
![iOS](https://img.shields.io/badge/iOS-26.0+-blue)
![Swift](https://img.shields.io/badge/Swift-6.0-orange)
![Rust](https://img.shields.io/badge/Rust-stable-red)
![License](https://img.shields.io/badge/license-MIT-green)

https://github.com/user-attachments/assets/58be4f6e-55f9-43fe-9336-d3db99c4471c

## Why

I don't write code anymore — agents do. My job is review, management, and guidance at the right time. But with multiple repos and a bunch of agents running across all of them, keeping track of it all was chaos. OrbitDock is how I wrangle that.

## What You Get

- **Live monitoring** — Watch every session across every project in real time
- **Code review** — Magit-style diffs with inline comments that steer the agent
- **Approval triage** — Diff previews, risk cues, keyboard shortcuts (y/n/!/N)
- **Direct control** — Create sessions, send messages, approve tools, run shell commands
- **Usage tracking** — Rate limit monitoring for Claude and Codex
- **Multi-server** — Connect to local, remote, and cloud endpoints at once

See [FEATURES.md](FEATURES.md) for the full list.

## Get Started

### 1. Install the server

```bash
curl -fsSL https://raw.githubusercontent.com/Robdel12/OrbitDock/main/orbitdock-server/install.sh | bash
```

This downloads a prebuilt binary (macOS / Linux x86_64) or builds from source as a fallback. It handles everything — data directory, database, Claude Code hooks, and a background service.

### 2. Run the app

Download from [Releases](https://github.com/Robdel12/OrbitDock/releases), or build from source:

```bash
git clone https://github.com/Robdel12/OrbitDock.git
cd OrbitDock
make build
open OrbitDock/OrbitDock.xcodeproj   # Cmd+R
```

The app detects the server automatically. Start a Claude Code or Codex session and it shows up in the dashboard.

### Remote server

For running the server on a VPS, Raspberry Pi, or another machine:

```bash
orbitdock-server setup --remote
```

See [DEPLOYMENT.md](DEPLOYMENT.md) for Cloudflare tunnels, TLS, Docker, and more.

## Requirements

- macOS 15.0+ (iOS 26.0+ for mobile)
- **Codex** is built in — the server embeds codex-core, so you get it out of the box with an OpenAI API key
- **Claude Code** requires a separate install and active login — OrbitDock monitors it via hooks
- Xcode 16+ and Rust stable toolchain if building from source

## Documentation

- [FEATURES.md](FEATURES.md) — Full feature list with keyboard shortcuts
- [DEPLOYMENT.md](DEPLOYMENT.md) — Server deployment guide (remote, TLS, tunnels)
- [CONTRIBUTING.md](CONTRIBUTING.md) — Development setup and architecture
- [orbitdock-server/README.md](orbitdock-server/README.md) — Server CLI reference

## License

[MIT](LICENSE)
