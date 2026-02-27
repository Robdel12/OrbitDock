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

See [FEATURES.md](FEATURES.md) for the full list.

## Get Started

### 1. Install the server

```bash
curl -fsSL https://raw.githubusercontent.com/Robdel12/OrbitDock/main/orbitdock-server/install.sh | bash
```

This downloads a prebuilt binary (macOS / Linux x86_64) or builds from source as a fallback. It
handles everything — data directory, database, Claude Code hooks, and a background service.

### 2. Run the app

Download from [Releases](https://github.com/Robdel12/OrbitDock/releases), or build from source:

```bash
git clone https://github.com/Robdel12/OrbitDock.git
cd OrbitDock
make build
open OrbitDock/OrbitDock.xcodeproj   # Cmd+R
```

The app detects the server automatically. Start a Claude Code or Codex session and it shows up in
the dashboard.

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
