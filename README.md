# OrbitDock

Mission control for AI coding agents. A native macOS app that monitors all your Claude Code and Codex CLI sessions from one dashboard — live status, conversations, code review, approvals, and usage tracking.

![macOS](https://img.shields.io/badge/macOS-14.0+-blue)
![Swift](https://img.shields.io/badge/Swift-5.9+-orange)
![Rust](https://img.shields.io/badge/Rust-1.75+-red)
![License](https://img.shields.io/badge/license-MIT-green)

## Why This Exists

I don't write code anymore — agents do. My job is review, management, and guidance at the right time.

The problem? I've got multiple products, lots of repos, and a bunch of LLM agents running across all of them. Keeping track of it all was chaos. Which session needs permission? Did that refactor finish? Is Claude waiting on me or still working? I'd cycle through terminal tabs trying to figure out what was happening where.

OrbitDock is how I wrangle all that. One dashboard to track every session across every project — live status, conversation history, code review, usage limits, and direct agent control.

## Features

- **Multi-Provider** — Claude Code and Codex CLI sessions in one place
- **Live Monitoring** — Watch conversations unfold with real-time status (Working, Permission, Question, Reply, Ended)
- **Review Canvas** — Magit-style code review with inline comments that steer the agent
- **Approval Oversight** — Diff previews, risk cues, keyboard triage (y/n/!/N)
- **Shell Execution** — Run shell commands in Codex sessions directly from the app
- **Direct Codex Control** — Create sessions, send messages, approve tools — no terminal needed
- **Usage Tracking** — Rate limit monitoring for both Claude and Codex
- **Quick Switcher (⌘K)** — Jump between sessions or run commands instantly
- **Focus Terminal (⌘T)** — Jump to the iTerm2 tab running a session
- **MCP Bridge** — Control Codex sessions from Claude Code via MCP tools
- **Local-First** — All data stays on your machine in SQLite

See [FEATURES.md](FEATURES.md) for the full list.

## Architecture

OrbitDock has two main pieces: a **SwiftUI macOS app** and a **Rust WebSocket server** embedded in the app bundle.

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
│  │             CodexConnector (codex-rs)              │    │
│  └──────────────────────────────────────────────────┘    │
│                                                          │
│  ┌──────────────────────────────────────────────────┐    │
│  │  Claude Code ← CLI hooks (orbitdock-cli)          │    │
│  │  Codex CLI   ← FSEvents watcher                   │    │
│  └──────────────────────────────────────────────────┘    │
│                                                          │
│  SQLite + WAL  (~/.orbitdock/orbitdock.db)                │
└─────────────────────────────────────────────────────────┘
```

**Claude Code** sessions are tracked via CLI hooks embedded in the app bundle. The hooks fire on lifecycle events (session start/end, tool use, status changes) and write to SQLite.

**Codex CLI** sessions are tracked two ways:
- **FSEvents watcher** — Watches `~/.codex/sessions/` rollout files for passive monitoring
- **Direct sessions** — The Rust server connects to codex-rs directly, enabling full control (send messages, approve tools, execute shell commands)

For the server's internal architecture (actor model, state machine, registry pattern), see [orbitdock-server/README.md](orbitdock-server/README.md).

## Quick Start

### Build from Source

```bash
git clone https://github.com/Robdel12/OrbitDock.git
cd OrbitDock
make build
```

Then open in Xcode:

```bash
open OrbitDock/OrbitDock.xcodeproj
```

Run with ⌘R. The Rust server and CLI are automatically embedded in the app bundle.

### Configure Claude Code Hooks

Add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": "/Applications/OrbitDock.app/Contents/MacOS/orbitdock-cli session-start", "async": true}]}],
    "SessionEnd": [{"hooks": [{"type": "command", "command": "/Applications/OrbitDock.app/Contents/MacOS/orbitdock-cli session-end", "async": true}]}],
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "/Applications/OrbitDock.app/Contents/MacOS/orbitdock-cli status-tracker", "async": true}]}],
    "Stop": [{"hooks": [{"type": "command", "command": "/Applications/OrbitDock.app/Contents/MacOS/orbitdock-cli status-tracker", "async": true}]}],
    "Notification": [{"hooks": [{"type": "command", "command": "/Applications/OrbitDock.app/Contents/MacOS/orbitdock-cli status-tracker", "async": true}]}],
    "PreToolUse": [{"hooks": [{"type": "command", "command": "/Applications/OrbitDock.app/Contents/MacOS/orbitdock-cli tool-tracker", "async": true}]}],
    "PostToolUse": [{"hooks": [{"type": "command", "command": "/Applications/OrbitDock.app/Contents/MacOS/orbitdock-cli tool-tracker", "async": true}]}],
    "PostToolUseFailure": [{"hooks": [{"type": "command", "command": "/Applications/OrbitDock.app/Contents/MacOS/orbitdock-cli tool-tracker", "async": true}]}],
    "SubagentStart": [{"hooks": [{"type": "command", "command": "/Applications/OrbitDock.app/Contents/MacOS/orbitdock-cli subagent-tracker", "async": true}]}],
    "SubagentStop": [{"hooks": [{"type": "command", "command": "/Applications/OrbitDock.app/Contents/MacOS/orbitdock-cli subagent-tracker", "async": true}]}],
    "PreCompact": [{"hooks": [{"type": "command", "command": "/Applications/OrbitDock.app/Contents/MacOS/orbitdock-cli status-tracker", "async": true}]}]
  }
}
```

Codex CLI support is automatic — no hook setup needed.

## Requirements

- macOS 14.0+
- Xcode 15+ and Rust toolchain (for building from source)
- At least one CLI: [Claude Code](https://docs.anthropic.com/en/docs/claude-code) or [Codex CLI](https://github.com/openai/codex)

## Project Structure

```
├── orbitdock-server/           # Rust WebSocket server
│   └── crates/
│       ├── server/             # Main server (actors, registry, persistence)
│       ├── protocol/           # Shared types (client ↔ server)
│       └── connectors/         # AI provider connectors (codex-rs)
├── OrbitDock/                  # Xcode project
│   ├── OrbitDock/              # SwiftUI macOS app
│   │   ├── Views/              # UI (dashboard, review canvas, tool cards)
│   │   ├── Services/           # Business logic, server connection
│   │   └── Models/             # Session, provider, protocol types
│   └── OrbitDockCore/          # Swift Package (shared code + CLI)
│       └── Sources/
│           ├── OrbitDockCore/  # Database, git ops, models
│           └── OrbitDockCLI/   # CLI hook handler
├── orbitdock-debug-mcp/        # MCP server for cross-agent control
├── migrations/                 # Database migrations (SQL)
└── plans/                      # Design docs and roadmaps
```

## Development

```bash
make build        # Build the app
make test-unit    # Unit tests (excludes UI tests)
make test-all     # All tests

make rust-build   # Build the Rust server
make rust-test    # Run server tests (96 tests)
make rust-check   # cargo check

make fmt          # Format Swift + Rust
make lint         # Lint Swift + Rust
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full development guide.

## License

[MIT](LICENSE)
