# OrbitDock

A native macOS SwiftUI app for monitoring and managing multiple Claude Code CLI sessions in real-time.

![macOS](https://img.shields.io/badge/macOS-14.0+-blue)
![Swift](https://img.shields.io/badge/Swift-5.9+-orange)
![License](https://img.shields.io/badge/license-MIT-green)

## Features

- **Live Session Monitoring** - See all active Claude Code sessions across your machine
- **Real-time Conversation View** - Watch conversations unfold with smooth animations
- **Work Status Tracking** - Know when Claude is working, waiting for input, or needs permission
- **Quick Switcher** - ⌘K to quickly jump between sessions or run commands
- **Session Management** - Rename, close, or resume sessions from the UI
- **Workstream Tracking** - Automatic grouping by git branch with PR/issue integration
- **Usage Tracking** - Monitor Anthropic API usage and rate limits
- **Focus Terminal** - Jump directly to the iTerm2 tab running a session
- **Dark Mode** - Cosmic harbor theme optimized for OLED displays

## Requirements

- macOS 14.0+
- Claude Code CLI installed (`npm install -g @anthropic-ai/claude-code`)
- Node.js 18+ (for hooks)
- Xcode 15+ (for building)

## Installation

### 1. Install dependencies

```bash
npm install
```

### 2. Run database migrations

```bash
./scripts/migrate.js
```

This creates the database at `~/.orbitdock/orbitdock.db` with the full schema.

### 3. Install the Claude Code hooks

Create a symlink to use hooks from this repo:

```bash
# Link the hooks directory
ln -sf "$(pwd)/hooks" ~/.claude/hooks
```

Or copy them manually:

```bash
mkdir -p ~/.claude/hooks
cp hooks/*.js ~/.claude/hooks/
```

### 4. Configure Claude Code to use the hooks

Add to your `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [{ "command": "node ~/.claude/hooks/session-start.js" }],
    "SessionEnd": [{ "command": "node ~/.claude/hooks/session-end.js" }],
    "PreToolUse": [{ "command": "node ~/.claude/hooks/tool-tracker.js" }],
    "PostToolUse": [{ "command": "node ~/.claude/hooks/tool-tracker.js" }],
    "Notification": [{ "command": "node ~/.claude/hooks/status-tracker.js" }],
    "Stop": [{ "command": "node ~/.claude/hooks/status-tracker.js" }]
  }
}
```

### 5. Build and run the app

Open `CommandCenter/CommandCenter.xcodeproj` in Xcode and build (⌘R).

## Database Migrations

OrbitDock uses a migration system for schema management. Migrations live in `migrations/` as numbered SQL files.

```bash
# Check migration status
./scripts/migrate.js status

# Run pending migrations
./scripts/migrate.js

# List all migrations
./scripts/migrate.js list
```

### Adding a new migration

1. Create a new file: `migrations/003_your_change.sql`
2. Write your SQL (tables, columns, indexes)
3. Run `./scripts/migrate.js` to apply

Migrations run automatically when hooks execute or when the app starts.

## Codex CLI Integration

Codex CLI writes session rollouts to `~/.codex/sessions/**/rollout-*.jsonl`. OrbitDock watches these files using native FSEvents and maps them into the same database schema.

**Notes:**
- The watcher stores offsets in `~/.orbitdock/codex-rollout-state.json`
- Only reacts to file changes (no polling), so old sessions appear after new activity

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      OrbitDock App                          │
│  ┌─────────────┐  ┌─────────────────────────────────────┐  │
│  │  Dashboard  │  │         Session Detail              │  │
│  │  - Active   │  │  - Header (status, model, branch)   │  │
│  │  - History  │  │  - Conversation View                │  │
│  │  - Streams  │  │  - Quick Actions                    │  │
│  └─────────────┘  └─────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
                    ┌─────────────────┐
                    │  SQLite + WAL   │
                    │  ~/.orbitdock/  │
                    │  orbitdock.db   │
                    └─────────────────┘
                              ▲
                              │
         ┌────────────────────┼────────────────────┐
         │                    │                    │
    ┌────┴────┐         ┌────┴────┐         ┌────┴────┐
    │ Session │         │ Status  │         │  Tool   │
    │  Hooks  │         │ Tracker │         │ Tracker │
    │  (JS)   │         │  (JS)   │         │  (JS)   │
    └─────────┘         └─────────┘         └─────────┘
```

## Project Structure

```
├── migrations/              # Database migrations (SQL)
├── lib/                     # Shared JS libraries
│   ├── db.js               # Database operations
│   ├── migrate.js          # Migration runner
│   ├── workstream.js       # Workstream logic
│   └── git.js              # Git utilities
├── hooks/                   # Claude Code hooks (JS)
│   ├── session-start.js
│   ├── session-end.js
│   ├── status-tracker.js
│   └── tool-tracker.js
├── scripts/                 # CLI tools
│   └── migrate.js          # Migration CLI
├── mcp-server/             # MCP server for workstreams
└── CommandCenter/          # SwiftUI macOS app
    ├── Database/
    │   ├── DatabaseManager.swift
    │   └── MigrationManager.swift
    ├── Models/
    ├── Services/
    └── Views/
```

## Development

### Running tests

```bash
npm test
```

### Environment variables

- `ORBITDOCK_DB_PATH` - Override database path (for testing)
- `ORBITDOCK_DEBUG` - Enable debug logging in hooks

## Permissions

The app requires **Automation** permission to control iTerm2 for the "Focus" feature:

`System Settings → Privacy & Security → Automation → OrbitDock → iTerm`

## License

MIT
