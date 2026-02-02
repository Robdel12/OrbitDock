# OrbitDock

Mission control for AI coding agents. A native macOS app that monitors Claude Code and Codex CLI sessions in real-time.

![macOS](https://img.shields.io/badge/macOS-14.0+-blue)
![Swift](https://img.shields.io/badge/Swift-5.9+-orange)
![License](https://img.shields.io/badge/license-MIT-green)

## Features

- **Multi-Provider Support** - Track both Claude Code and Codex CLI sessions
- **Live Session Monitoring** - See all active AI agent sessions across your machine
- **Real-time Conversation View** - Watch conversations unfold with smooth animations
- **Work Status Tracking** - Know when an agent is working, waiting for input, or needs permission
- **Quick Switcher** - ⌘K to quickly jump between sessions or run commands
- **Session Management** - Rename, close, or resume sessions from the UI
- **Workstream Tracking** - Automatic grouping by git branch with PR/issue integration
- **Usage Tracking** - Monitor rate limits for both Claude and Codex
- **Focus Terminal** - Jump directly to the iTerm2 tab running a session
- **Dark Mode** - Cosmic harbor theme optimized for OLED displays

## Supported Providers

| Provider | Session Tracking | Usage Monitoring | Notes |
|----------|-----------------|------------------|-------|
| **Claude Code** | Hooks (JS) | OAuth API | Full support via lifecycle hooks |
| **Codex CLI** | Native FSEvents | App Server API | Watches `~/.codex/sessions/` rollouts |

## Requirements

- macOS 14.0+
- Node.js 18+
- Xcode 15+ (for building from source)
- At least one CLI installed:
  - Claude Code: `npm install -g @anthropic-ai/claude-code`
  - Codex CLI: See [OpenAI Codex docs](https://openai.com/codex)

## Quick Start

### 1. Clone and install

```bash
git clone https://github.com/your-username/orbitdock.git
cd orbitdock
node install.js
```

The installer:
- Installs npm dependencies
- Configures Claude Code hooks in `~/.claude/settings.json`
- Sets up the MCP server in `~/.claude/mcp.json`
- Creates the database at `~/.orbitdock/orbitdock.db`

### 2. Restart your CLI

Restart Claude Code (or start a new session) to activate the hooks.

### 3. Build and run the app

Open `CommandCenter/CommandCenter.xcodeproj` in Xcode and build (⌘R).

**Note:** Codex CLI support is automatic - no hook setup needed. OrbitDock watches `~/.codex/sessions/` using native FSEvents.

## Manual Installation (Alternative)

If you prefer manual setup:

```bash
# 1. Install dependencies
npm install

# 2. Run database migrations
./scripts/migrate.js

# 3. Add hooks to ~/.claude/settings.json manually
# See hooks/README.md for the full hook configuration
```

## Database Migrations

OrbitDock uses a migration system for schema management. Migrations live in `migrations/` as numbered SQL files.

```bash
./scripts/migrate.js status  # Check migration status
./scripts/migrate.js         # Run pending migrations
./scripts/migrate.js list    # List all migrations
```

Migrations run automatically when hooks execute or when the app starts.

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                        OrbitDock App                              │
│  ┌─────────────┐  ┌──────────────────────────────────────────┐  │
│  │  Dashboard  │  │            Session Detail                 │  │
│  │  - Active   │  │  - Header (status, model, provider)       │  │
│  │  - History  │  │  - Conversation View                      │  │
│  │  - Streams  │  │  - Quick Actions                          │  │
│  └─────────────┘  └──────────────────────────────────────────┘  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │    Usage Panel - Claude (5h/7d) + Codex (rate windows)   │   │
│  └──────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────┘
                                │
                                ▼
                      ┌─────────────────┐
                      │  SQLite + WAL   │
                      │  ~/.orbitdock/  │
                      │  orbitdock.db   │
                      └─────────────────┘
                                ▲
           ┌────────────────────┴────────────────────┐
           │                                         │
   ┌───────┴───────┐                       ┌─────────┴─────────┐
   │  Claude Code  │                       │    Codex CLI      │
   │    Hooks      │                       │  FSEvents Watcher │
   │     (JS)      │                       │     (Swift)       │
   └───────────────┘                       └───────────────────┘
```

### Provider Integration Details

**Claude Code** uses JavaScript hooks configured in `~/.claude/settings.json`:
- `session-start.js` / `session-end.js` - Lifecycle tracking
- `status-tracker.js` - Work status and attention states
- `tool-tracker.js` - Tool usage analytics

**Codex CLI** uses native FSEvents watching:
- Watches `~/.codex/sessions/` for rollout JSONL files
- Parses session_meta, event_msg, and response_item entries
- State persisted in `~/.orbitdock/codex-rollout-state.json`

## Project Structure

```
├── install.js               # One-command installer
├── migrations/              # Database migrations (SQL)
├── lib/                     # Shared JS libraries
│   ├── db.js               # Database operations
│   ├── migrate.js          # Migration runner
│   ├── workstream.js       # Workstream logic
│   └── git.js              # Git utilities
├── hooks/                   # Claude Code hooks (JS)
│   ├── session-start.js    # Session lifecycle
│   ├── session-end.js
│   ├── status-tracker.js   # Work status tracking
│   ├── tool-tracker.js     # Tool usage
│   └── codex-notify.js     # Codex turn-complete hook
├── scripts/
│   └── migrate.js          # Migration CLI
├── mcp-server/             # MCP server for workstreams
└── CommandCenter/          # SwiftUI macOS app
    ├── Models/
    │   ├── Provider.swift  # Multi-provider enum
    │   └── Session.swift   # Unified session model
    ├── Services/
    │   ├── UsageServiceRegistry.swift     # Coordinates all providers
    │   ├── SubscriptionUsageService.swift # Claude usage API
    │   ├── CodexUsageService.swift        # Codex usage API
    │   └── CodexRolloutWatcher.swift      # Native FSEvents watcher
    └── Views/
        └── Usage/          # Provider usage gauges
```

## Development

### Running tests

```bash
npm test
```

### Environment variables

| Variable | Description |
|----------|-------------|
| `ORBITDOCK_DB_PATH` | Override database path (for testing) |
| `ORBITDOCK_DEBUG` | Enable debug logging in hooks |
| `ORBITDOCK_DISABLE_CODEX_WATCHER` | Disable the Codex FSEvents watcher |
| `ORBITDOCK_CODEX_WATCHER_DEBUG` | Verbose logging for Codex watcher |

### Debugging hooks

```bash
# Watch hook logs
tail -f ~/.orbitdock/hooks.log

# Check database directly
sqlite3 ~/.orbitdock/orbitdock.db "SELECT id, work_status FROM sessions LIMIT 5;"
```

## Permissions

The app requires **Automation** permission to control iTerm2 for the "Focus" feature:

`System Settings → Privacy & Security → Automation → OrbitDock → iTerm`

## Troubleshooting

**Sessions not appearing?**
- For Claude Code: Restart the CLI after installing hooks
- For Codex: Check that `~/.codex/sessions/` exists and has JSONL files

**Usage data not loading?**
- Claude: Ensure you're logged in (`claude login`)
- Codex: Check the app server is reachable

**Hooks not firing?**
- Run `ORBITDOCK_DEBUG=1 claude` to see hook output
- Check `~/.orbitdock/hooks.log` for errors

## License

MIT
