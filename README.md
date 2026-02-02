# OrbitDock

Mission control for AI coding agents. A native macOS app that lets you monitor all your Claude Code and Codex CLI sessions from one place—like a cosmic harbor where your AI crews dock and report in.

![macOS](https://img.shields.io/badge/macOS-14.0+-blue)
![Swift](https://img.shields.io/badge/Swift-5.9+-orange)
![License](https://img.shields.io/badge/license-MIT-green)

## Why I Built This

I don't write code anymore (like 98% of the time). Agents do. My job now is review, management, and guidance at the right time.

I've got one real SaaS product (with something like 5 repos and 10 SDKs), plus a couple other products I'm building that don't have users yet. That's a lot of projects, a lot of tasks within those projects, and a lot of LLM agents running around in all of them.

The problem? Keeping track of it all. Which session needs permission? Did that refactor finish? Is Claude waiting on me or still working? I'd find myself cycling through terminal tabs trying to figure out what was happening where.

OrbitDock is how I wrangle all that chaos. One dashboard to track every session across every project—live status updates, conversation history, usage limits, and quick terminal access. It's mission control for my new way of working.

## Features

- **Multi-Provider Support** - Track Claude Code and Codex CLI sessions together
- **Live Session Monitoring** - Watch conversations unfold in real-time
- **5-State Status System** - Working, Permission, Question, Reply, Ended
- **Quick Switcher (⌘K)** - Jump between sessions or run commands instantly
- **Workstream Tracking** - Automatic grouping by git branch with PR/issue integration
- **Usage Tracking** - Monitor rate limits for both Claude and Codex
- **Focus Terminal (⌘T)** - Jump directly to the iTerm2 tab running a session
- **Cosmic Harbor Theme** - Dark theme optimized for OLED displays

See [FEATURES.md](FEATURES.md) for the full feature list.

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

The installer handles everything:
- Installs npm dependencies
- Configures Claude Code hooks in `~/.claude/settings.json`
- Sets up the MCP server in `~/.claude/mcp.json`
- Creates the database at `~/.orbitdock/orbitdock.db`

### 2. Restart your CLI

Restart Claude Code (or start a new session) to activate the hooks.

### 3. Build and run the app

Open `CommandCenter/CommandCenter.xcodeproj` in Xcode and hit ⌘R.

**Note:** Codex CLI support is automatic—no hook setup needed. OrbitDock watches `~/.codex/sessions/` using native FSEvents.

## Manual Installation

If you prefer doing things by hand:

```bash
# 1. Install dependencies
npm install

# 2. Run database migrations
./scripts/migrate.js

# 3. Add hooks to ~/.claude/settings.json manually
# See hooks/README.md for the full hook configuration
```

## Architecture

Here's how the pieces fit together:

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

### Provider Integration

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

## Database Migrations

OrbitDock uses a migration system for schema changes. Migrations live in `migrations/` as numbered SQL files.

```bash
./scripts/migrate.js status  # Check migration status
./scripts/migrate.js         # Run pending migrations
./scripts/migrate.js list    # List all migrations
```

Migrations run automatically when hooks execute or when the app starts.

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

The app needs **Automation** permission to control iTerm2 for the Focus feature:

`System Settings → Privacy & Security → Automation → OrbitDock → iTerm`

## Troubleshooting

**Sessions not appearing?**
- For Claude Code: Restart the CLI after installing hooks
- For Codex: Check that `~/.codex/sessions/` exists and has JSONL files

**Usage data not loading?**
- Claude: Make sure you're logged in (`claude login`)
- Codex: Check the app server is reachable

**Hooks not firing?**
- Run `ORBITDOCK_DEBUG=1 claude` to see hook output
- Check `~/.orbitdock/hooks.log` for errors

## License

MIT
