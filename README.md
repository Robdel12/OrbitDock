# OrbitDock

Mission control for AI coding agents.

![macOS](https://img.shields.io/badge/macOS-15.0+-blue)
![iOS](https://img.shields.io/badge/iOS-18.0+-blue)
![Swift](https://img.shields.io/badge/Swift-5.0-orange)
![Rust](https://img.shields.io/badge/Rust-stable-red)
![License](https://img.shields.io/badge/license-MIT-green)


https://github.com/user-attachments/assets/b1e23968-6196-45b3-8b86-c177b3e59e6d


## Why

I don't write code anymore (pretty much) — agents do. My job is reviewing, managing, and
providing guidance at the right time. But with multiple repos and a bunch of agents running
across all of them, keeping track of it all was chaos. OrbitDock is how I'm trying to wrangle that.

A Rust server sits at the center. It creates and runs both Claude Code and Codex sessions
directly — Codex via embedded codex-core, Claude via the CLI. It also picks up existing Claude
Code terminal sessions through hooks. Run a server on your laptop, your work machine, a VPS,
wherever your agents are. The macOS and iOS apps connect to all of them at once, so you get one
unified view no matter where your sessions are running or what device you're on.

## Beyond basic hooks

Most Claude Code setups pipe hooks into a script and call it a day. OrbitDock goes further.

**Bidirectional, not just passive.** Hooks tell you what's happening. OrbitDock lets you act on
it. Send messages, steer mid-turn, fork conversations, roll back turns — all from the app. You
can also take over a passive hook-monitored session and convert it to full direct control
without interrupting it.

**Both providers, one place.** Claude Code and Codex from the same dashboard, same approval
flow, same review canvas. Pick whichever agent fits the task and manage them the same way.

**Code review that feeds back.** A magit-style diff view shows exactly what the agent changed.
Add inline comments on specific lines, then send them as structured feedback. The agent gets
your context and corrects course — no copy-pasting out of a terminal.

**Approve from anywhere.** Tool calls, permission requests, and questions don't wait for you to
be at your desk. The iOS app puts approvals, diffs, and session status in your pocket. Unblock
an agent from your phone and it keeps going.

**Mission Control.** Point it at a Linear project and it pulls issues, creates per-issue git
worktrees, dispatches agents automatically, and reports back. Configurable provider strategy,
retry logic, and a Liquid prompt template so each agent knows what it's working on. Hands-off
orchestration with human-in-the-loop controls when you need them.

**Multi-server.** Your laptop, your VPS, a Raspberry Pi in a drawer — connect all of them at
once. Sessions from every endpoint merge into one dashboard so nothing slips through the cracks.

## What You Get

- **Run agents from anywhere** — Create Claude and Codex sessions from Mac or iOS, no terminal needed
- **Live monitoring** — Every session across every project, updating in real time
- **Code review** — Magit-style diffs with inline comments that steer the agent
- **Approval triage** — Diff previews, risk cues, keyboard shortcuts (y/n/!/N)
- **Direct control** — Send messages, approve tools, interrupt, run shell commands
- **Usage tracking** — Rate limit monitoring for Claude and Codex
- **Multi-server** — Connect to local, remote, and cloud endpoints at once
- **Mission Control** — Autonomous issue-driven orchestration via Linear

See [FEATURES.md](docs/FEATURES.md) for the full list.

## Quickstart

### 1. Install the server

```bash
curl -fsSL https://raw.githubusercontent.com/Robdel12/OrbitDock/main/orbitdock-server/install.sh | bash
```

The installer sets up the binary, shell `PATH`, data directory, and database. It then asks whether
you want to install Claude hooks and whether you want OrbitDock running as a background service.

### 2. Start or verify the server

```bash
orbitdock status
orbitdock doctor
```

If you skipped the background service during install, start it manually:

```bash
orbitdock start
```

`doctor` runs a full diagnostic — database, hooks, encryption key, disk space, port availability,
and more. If something's wrong, it'll tell you.

### 3. Open the app

Download from [Releases](https://github.com/Robdel12/OrbitDock/releases) and run it.

Or build from source:

```bash
git clone https://github.com/Robdel12/OrbitDock.git
cd OrbitDock
make build
```

You can also open `OrbitDockNative/OrbitDock.xcodeproj` in Xcode and hit Cmd+R.

The app auto-connects to the local server.

### 4. Authenticate your providers

**Codex** — Open Settings → CODEX CLI → Sign in with ChatGPT (or use API key auth mode).

**Claude Code** — Install the [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code/overview) and log in. If you skipped hook setup during install, run `orbitdock install-hooks`.

### 5. Create a session

Click **New** in the top bar and pick **Claude Session** or **Codex Session**. Select a project
directory, choose your model, and go.

Existing Claude Code terminal sessions show up automatically through hooks.

If something doesn't appear, run `orbitdock doctor` and check `~/.orbitdock/logs/server.log`.

### Remote server

Running on a VPS, Raspberry Pi, NAS, or another machine:

```bash
# On the server
orbitdock remote-setup

# On your developer machine
orbitdock install-hooks --server-url https://your-server.example.com:4000
```

`remote-setup` guides secure exposure, creates a fresh auth token, and tells you the exact next commands
for pairing clients and forwarding hooks. For the app, add the same server URL and token in Settings → Servers.

See [DEPLOYMENT.md](docs/DEPLOYMENT.md) for Cloudflare tunnels, TLS, reverse proxies, and Raspberry Pi notes.

## Requirements

- macOS 15.0+ (iOS 18.0+ for mobile)
- Codex — built in, authenticates with ChatGPT sign-in or API key
- Claude Code — requires the `claude` CLI installed and logged in
- Xcode 16+ and Rust stable toolchain if building from source

## Documentation

- [FEATURES.md](docs/FEATURES.md) — Full feature list with keyboard shortcuts
- [DEPLOYMENT.md](docs/DEPLOYMENT.md) — Server deployment (remote, TLS, tunnels)
- [CONTRIBUTING.md](docs/CONTRIBUTING.md) — Development setup and architecture
- [orbitdock-server/README.md](orbitdock-server/README.md) — Server CLI reference
- [orbitdock-server/docs/API.md](orbitdock-server/docs/API.md) — HTTP and WebSocket contract

## License

[MIT](LICENSE)
