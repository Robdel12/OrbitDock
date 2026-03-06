# OrbitDock

Mission control for AI coding agents. Manage Claude Code and Codex sessions from your Mac or
your phone — create sessions, review diffs, approve tools, and steer agents from anywhere.

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

## What You Get

- **Run agents from anywhere** — Create Claude and Codex sessions from Mac or iOS, no terminal needed
- **Live monitoring** — Every session across every project, updating in real time
- **Code review** — Magit-style diffs with inline comments that steer the agent
- **Approval triage** — Diff previews, risk cues, keyboard shortcuts (y/n/!/N)
- **Direct control** — Send messages, approve tools, interrupt, run shell commands
- **Usage tracking** — Rate limit monitoring for Claude and Codex
- **Multi-server** — Connect to local, remote, and cloud endpoints at once

See [FEATURES.md](docs/FEATURES.md) for the full list.

## Quickstart

Get this running locally in a few minutes.

### 1. Install the server

```bash
curl -fsSL https://raw.githubusercontent.com/Robdel12/OrbitDock/main/orbitdock-server/install.sh | bash
```

The installer sets up the binary, shell `PATH`, data directory, database, Claude hooks, and background service.

### 2. Verify it started

```bash
orbitdock status
orbitdock doctor
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

You can also open `OrbitDock/OrbitDock.xcodeproj` in Xcode and hit Cmd+R.

The app auto-connects to the local server.

### 4. Authenticate your providers

**Codex** — Open Settings → CODEX CLI → Sign in with ChatGPT (or use API key auth mode).

**Claude Code** — Install the [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code/overview) and log in. The installer already set up hooks, but if you skipped that step: `orbitdock install-hooks`.

### 5. Create a session

Click **New** in the top bar and pick **Claude Session** or **Codex Session**. Select a project
directory, choose your model, and go.

Existing Claude Code terminal sessions show up automatically through hooks.

If something doesn't appear, run `orbitdock doctor` and check `~/.orbitdock/logs/server.log`.

### Remote server

Running on a VPS, Raspberry Pi, NAS, or another machine:

```bash
# On the server
orbitdock setup --remote --server-url https://your-server.example.com:4000

# On your developer machine
orbitdock install-hooks --server-url https://your-server.example.com:4000
```

`install-hooks` prompts for the token that `setup --remote` prints and stores it encrypted for local hook forwarding.
For the app, add the same server URL and token in Settings → Servers.

See [DEPLOYMENT.md](docs/DEPLOYMENT.md) for Cloudflare tunnels, TLS, reverse proxies, and Raspberry Pi notes.

## Requirements

- macOS 15.0+ (iOS 18.0+ for mobile)
- **Codex** — Built in. The server embeds codex-core. Authenticate with ChatGPT sign-in or API key
- **Claude Code** — Requires the `claude` CLI installed and logged in. OrbitDock creates sessions directly or monitors existing ones via hooks
- Xcode 16+ and Rust stable toolchain if building from source

## Documentation

- [FEATURES.md](docs/FEATURES.md) — Full feature list with keyboard shortcuts
- [DEPLOYMENT.md](docs/DEPLOYMENT.md) — Server deployment guide (remote, TLS, tunnels)
- [CONTRIBUTING.md](docs/CONTRIBUTING.md) — Development setup and architecture
- [orbitdock-server/README.md](orbitdock-server/README.md) — Server CLI reference

## License

[MIT](LICENSE)
