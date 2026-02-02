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
| **Claude Code** | CLI hooks + FSEvents | OAuth API | Hooks for status, FSEvents for transcripts |
| **Codex CLI** | Native FSEvents | App Server API | Watches `~/.codex/sessions/` rollouts |

## Requirements

- macOS 14.0+
- Xcode 15+ (for building from source)
- At least one CLI installed:
  - Claude Code: `npm install -g @anthropic-ai/claude-code`
  - Codex CLI: See [OpenAI Codex docs](https://openai.com/codex)

## Quick Start

### Option 1: Download Release

1. Download the latest `.dmg` from [Releases](https://github.com/your-username/orbitdock/releases)
2. Drag `OrbitDock.app` to `/Applications`
3. Open the app and go to **Settings → Setup**
4. Copy the hook configuration and add it to `~/.claude/settings.json`
5. Restart Claude Code to activate hooks

### Option 2: Build from Source

```bash
git clone https://github.com/your-username/orbitdock.git
cd orbitdock
open CommandCenter/CommandCenter.xcodeproj
```

Build and run with ⌘R. The CLI is automatically embedded in the app bundle.

**Note:** Codex CLI support is automatic—no hook setup needed. OrbitDock watches `~/.codex/sessions/` using native FSEvents.

## Hook Configuration

Add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": "/Applications/OrbitDock.app/Contents/MacOS/orbitdock-cli session-start", "async": true}]}],
    "SessionEnd": [{"hooks": [{"type": "command", "command": "/Applications/OrbitDock.app/Contents/MacOS/orbitdock-cli session-end", "async": true}]}],
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "/Applications/OrbitDock.app/Contents/MacOS/orbitdock-cli status-tracker", "async": true}]}],
    "Stop": [{"hooks": [{"type": "command", "command": "/Applications/OrbitDock.app/Contents/MacOS/orbitdock-cli status-tracker", "async": true}]}],
    "Notification": [{"matcher": "idle_prompt|permission_prompt", "hooks": [{"type": "command", "command": "/Applications/OrbitDock.app/Contents/MacOS/orbitdock-cli status-tracker", "async": true}]}],
    "PreToolUse": [{"hooks": [{"type": "command", "command": "/Applications/OrbitDock.app/Contents/MacOS/orbitdock-cli tool-tracker", "async": true}]}],
    "PostToolUse": [{"hooks": [{"type": "command", "command": "/Applications/OrbitDock.app/Contents/MacOS/orbitdock-cli tool-tracker", "async": true}]}],
    "PostToolUseFailure": [{"hooks": [{"type": "command", "command": "/Applications/OrbitDock.app/Contents/MacOS/orbitdock-cli tool-tracker", "async": true}]}]
  }
}
```

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
   │   Swift CLI   │                       │  FSEvents Watcher │
   │  (embedded)   │                       │     (Swift)       │
   └───────────────┘                       └───────────────────┘
```

### Provider Integration

**Claude Code** uses a Swift CLI embedded in the app bundle:
- `orbitdock-cli session-start/end` - Lifecycle tracking
- `orbitdock-cli status-tracker` - Work status and attention states
- `orbitdock-cli tool-tracker` - Tool usage analytics

**Codex CLI** uses native FSEvents watching:
- Watches `~/.codex/sessions/` for rollout JSONL files
- Parses session_meta, event_msg, and response_item entries
- State persisted in `~/.orbitdock/codex-rollout-state.json`

## Project Structure

```
├── migrations/              # Database migrations (SQL)
└── CommandCenter/          # Xcode project
    ├── OrbitDockCore/      # Shared Swift package
    │   └── Sources/
    │       ├── OrbitDockCore/    # Database, Git, Models
    │       └── OrbitDockCLI/     # CLI hook handler
    └── CommandCenter/      # SwiftUI macOS app
        ├── Models/
        │   ├── Provider.swift    # Multi-provider enum
        │   └── Session.swift     # Unified session model
        ├── Services/
        │   ├── UsageServiceRegistry.swift     # Coordinates all providers
        │   ├── SubscriptionUsageService.swift # Claude usage API
        │   ├── CodexUsageService.swift        # Codex usage API
        │   └── CodexRolloutWatcher.swift      # Native FSEvents watcher
        └── Views/
            └── Usage/          # Provider usage gauges
```

## Development

### Building the CLI standalone

```bash
cd CommandCenter/OrbitDockCore
swift build
.build/debug/orbitdock-cli --help
```

### Debugging

```bash
# Check CLI logs
tail -f ~/.orbitdock/cli.log

# Check database directly
sqlite3 ~/.orbitdock/orbitdock.db "SELECT id, work_status FROM sessions LIMIT 5;"
```

### Environment variables

| Variable | Description |
|----------|-------------|
| `ORBITDOCK_DB_PATH` | Override database path (for testing) |
| `ORBITDOCK_DISABLE_CODEX_WATCHER` | Disable the Codex FSEvents watcher |
| `ORBITDOCK_CODEX_WATCHER_DEBUG` | Verbose logging for Codex watcher |

## Permissions

The app needs **Automation** permission to control iTerm2 for the Focus feature:

`System Settings → Privacy & Security → Automation → OrbitDock → iTerm`

## Troubleshooting

**Sessions not appearing?**
- For Claude Code: Restart the CLI after configuring hooks
- For Codex: Check that `~/.codex/sessions/` exists and has JSONL files

**Usage data not loading?**
- Claude: Make sure you're logged in (`claude login`)
- Codex: Check the app server is reachable

**Hooks not firing?**
- Check `~/.orbitdock/cli.log` for errors
- Verify the CLI path in settings.json matches your app location

## License

MIT
