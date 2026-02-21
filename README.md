# OrbitDock

Mission control for AI coding agents. A native macOS app that monitors all your Claude Code and Codex sessions from one dashboard — live status, conversations, code review, approvals, and usage tracking.

![macOS](https://img.shields.io/badge/macOS-14.0+-blue)
![Swift](https://img.shields.io/badge/Swift-5.9+-orange)
![Rust](https://img.shields.io/badge/Rust-1.75+-red)
![License](https://img.shields.io/badge/license-MIT-green)

## Why This Exists

I don't write code anymore — agents do. My job is review, management, and guidance at the right time.

The problem? I've got multiple products, lots of repos, and a bunch of LLM agents running across all of them. Keeping track of it all was chaos. Which session needs permission? Did that refactor finish? Is Claude waiting on me or still working? I'd cycle through terminal tabs trying to figure out what was happening where.

OrbitDock is how I wrangle all that. One dashboard to track every session across every project — live status, conversation history, code review, usage limits, and direct agent control.

## Features

- **Multi-Provider** — Claude Code and Codex sessions in one place
- **Live Monitoring** — Watch conversations unfold with real-time status (Working, Permission, Question, Reply, Ended)
- **Review Canvas** — Magit-style code review with inline comments that steer the agent
- **Approval Oversight** — Diff previews, risk cues, keyboard triage (y/n/!/N)
- **Shell Execution** — Run shell commands in Codex sessions directly from the app
- **Direct Codex Control** — Create sessions, send messages, approve tools — no terminal needed
- **Usage Tracking** — Rate limit monitoring for both Claude and Codex
- **Quick Switcher (Cmd+K)** — Jump between sessions or run commands instantly
- **Focus Terminal (Cmd+T)** — Jump to the iTerm2 tab running a session
- **MCP Bridge** — Control Codex sessions from Claude Code via MCP tools
- **Local-First** — All data stays on your machine in SQLite

See [FEATURES.md](FEATURES.md) for the full list.

## Quick Start

### macOS App

```bash
git clone https://github.com/Robdel12/OrbitDock.git
cd OrbitDock
make build
open OrbitDock/OrbitDock.xcodeproj
```

Hit Cmd+R. On first launch, the app checks if the server is reachable. If it is (you're running `cargo run`, brew, or launchd), you'll go straight to the dashboard. If not, you'll see a setup view that walks you through installation.

### Server Setup

The server runs separately from the app — as a background service, a manual `cargo run`, or on a remote machine.

**From the app:** Click "Install Locally" in the setup view. It copies the binary to `~/.orbitdock/bin/`, runs `init` and `install-hooks`, and registers a launchd service that auto-starts at login.

**From the CLI:** Build and set up manually if you prefer:

```bash
cd orbitdock-server && cargo build --release

orbitdock-server init             # create data dir, database, hook script
orbitdock-server install-hooks    # wire up Claude Code hooks
orbitdock-server start            # start listening on :4000
```

**As a system service:**

```bash
orbitdock-server install-service --enable   # launchd on macOS, systemd on Linux
```

**For development:** Just `cargo run -p orbitdock-server` — the app detects it via health check and connects.

You'll need [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed already — `install-hooks` writes to its settings file.

Codex direct sessions work out of the box. The server embeds codex-core, so you can create and control Codex sessions without a separate CLI.

**Remote setups:**

```bash
orbitdock-server generate-token
orbitdock-server start --bind 0.0.0.0:4000 --auth-token $(cat ~/.orbitdock/auth-token)
```

In the app, use "Connect to Remote Server" and enter the IP address.

See [orbitdock-server/README.md](orbitdock-server/README.md) for the full CLI reference.

### Hook Setup

If you ran `orbitdock-server install-hooks`, you're already set.

Otherwise, add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": "~/.orbitdock/hook.sh claude_session_start"}]}],
    "SessionEnd": [{"hooks": [{"type": "command", "command": "~/.orbitdock/hook.sh claude_session_end"}]}],
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "~/.orbitdock/hook.sh claude_status_event"}]}],
    "Stop": [{"hooks": [{"type": "command", "command": "~/.orbitdock/hook.sh claude_status_event"}]}],
    "Notification": [{"hooks": [{"type": "command", "command": "~/.orbitdock/hook.sh claude_status_event"}]}],
    "PreToolUse": [{"hooks": [{"type": "command", "command": "~/.orbitdock/hook.sh claude_tool_event"}]}],
    "PostToolUse": [{"hooks": [{"type": "command", "command": "~/.orbitdock/hook.sh claude_tool_event"}]}],
    "PostToolUseFailure": [{"hooks": [{"type": "command", "command": "~/.orbitdock/hook.sh claude_tool_event"}]}],
    "SubagentStart": [{"hooks": [{"type": "command", "command": "~/.orbitdock/hook.sh claude_subagent_event"}]}],
    "SubagentStop": [{"hooks": [{"type": "command", "command": "~/.orbitdock/hook.sh claude_subagent_event"}]}],
    "PreCompact": [{"hooks": [{"type": "command", "command": "~/.orbitdock/hook.sh claude_status_event"}]}]
  }
}
```

Codex sessions are picked up automatically — no hook config needed.

## Architecture

Two main pieces: a **SwiftUI macOS app** and a **Rust WebSocket server**. The server runs standalone — as a launchd service, via `cargo run`, or on a remote machine. The app connects over WebSocket.

```
┌─────────────────────────────────────────────────────────┐
│                   OrbitDock.app (SwiftUI)                │
│                                                          │
│  Dashboard ←→ Session Detail ←→ Review Canvas            │
│       │              │                │                   │
│       └──────────────┴────────────────┘                   │
│                      │ WebSocket                          │
│                      ▼                                    │
│  ┌──────────────────────────────────────────────────┐    │
│  │        orbitdock-server (Rust + Tokio)            │    │
│  │                                                    │    │
│  │  SessionRegistry ──► SessionActor (per session)    │    │
│  │       │                    │                       │    │
│  │       │              TransitionFn (pure)           │    │
│  │       │                    │                       │    │
│  │       └──── Persistence ───┘                       │    │
│  │                    │                               │    │
│  │             CodexConnector (codex-core)            │    │
│  └──────────────────────────────────────────────────┘    │
│                                                          │
│  ┌──────────────────────────────────────────────────┐    │
│  │  Claude Code ← hook.sh (HTTP POST to server)      │    │
│  │  Codex CLI   ← FSEvents watcher                   │    │
│  └──────────────────────────────────────────────────┘    │
│                                                          │
│  SQLite + WAL  (~/.orbitdock/orbitdock.db)                │
└─────────────────────────────────────────────────────────┘
```

**Claude Code** sessions are tracked via `~/.orbitdock/hook.sh`, which POSTs events to the server. If the server is offline, events get spooled to disk and drained on next startup.

**Codex** sessions are tracked two ways:
- **Passive** — A file watcher monitors `~/.codex/sessions/` for rollout files
- **Direct** — The server connects to codex-core for full control (send messages, approve tools, run shell commands)

For the server internals (actor model, state machine, registry), see [orbitdock-server/README.md](orbitdock-server/README.md).

## Requirements

- macOS 14.0+
- Xcode 15+ and Rust toolchain (for building from source)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) for Claude session tracking

## Project Structure

```
├── orbitdock-server/           # Rust server (standalone binary)
│   └── crates/
│       ├── server/             # Main binary — actors, persistence, CLI
│       ├── protocol/           # Shared types (client ↔ server)
│       └── connectors/         # AI provider connectors (codex-core)
├── OrbitDock/                  # Xcode project
│   ├── OrbitDock/              # SwiftUI macOS app
│   │   ├── Views/              # Dashboard, review canvas, tool cards
│   │   ├── Services/           # Server connection, business logic
│   │   └── Models/             # Session, provider, protocol types
│   └── OrbitDockCore/          # Swift Package (shared code)
├── orbitdock-debug-mcp/        # MCP server for cross-agent control
├── migrations/                 # SQL migrations (embedded in server at compile time)
└── scripts/
    ├── hook.sh                 # Dev-time hook script
    └── hook.sh.template        # Template for standalone deploy
```

## Development

```bash
make build        # Build the macOS app
make test-unit    # Unit tests (no UI automation)
make test-all     # Everything

make rust-check   # cargo check
make rust-test    # Server tests
make fmt          # Format Swift + Rust
make lint         # Lint Swift + Rust
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full guide.

## License

[MIT](LICENSE)
