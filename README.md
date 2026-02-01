# Command Center

A native macOS SwiftUI app for monitoring and managing multiple Claude Code CLI sessions in real-time.

![macOS](https://img.shields.io/badge/macOS-14.0+-blue)
![Swift](https://img.shields.io/badge/Swift-5.9+-orange)
![License](https://img.shields.io/badge/license-MIT-green)

## Features

- **Live Session Monitoring** - See all active Claude Code sessions across your machine
- **Real-time Conversation View** - Watch conversations unfold with smooth animations
- **Work Status Tracking** - Know when Claude is working, waiting for input, or needs permission
- **Context Window Usage** - Visual indicator showing how much context is used
- **Cost Tracking** - Monitor token usage and estimated costs per session
- **Focus Terminal** - Jump directly to the iTerm2 tab running a session
- **Resume Sessions** - Open ended sessions in a new terminal with one click
- **Session Labels** - Tag sessions with custom labels for organization
- **Dark Mode** - True black/dark gray theme optimized for OLED displays

## Requirements

- macOS 14.0+
- Claude Code CLI installed (`npm install -g @anthropic-ai/claude-code`)
- Xcode 15+ (for building)
- SQLite (included with macOS)

## Installation

### 1. Set up the database

```bash
sqlite3 ~/.claude/dashboard.db << 'EOF'
CREATE TABLE IF NOT EXISTS sessions (
  id TEXT PRIMARY KEY,
  project_path TEXT NOT NULL,
  project_name TEXT,
  branch TEXT,
  model TEXT,
  context_label TEXT,
  transcript_path TEXT,
  status TEXT DEFAULT 'active',
  started_at DATETIME,
  ended_at DATETIME,
  end_reason TEXT,
  total_tokens INTEGER DEFAULT 0,
  total_cost_usd REAL DEFAULT 0,
  last_activity_at DATETIME,
  work_status TEXT DEFAULT 'unknown',
  last_tool TEXT,
  last_tool_at DATETIME,
  prompt_count INTEGER DEFAULT 0,
  tool_count INTEGER DEFAULT 0,
  terminal_session_id TEXT,
  terminal_app TEXT
);
CREATE INDEX IF NOT EXISTS idx_sessions_status ON sessions(status);
CREATE INDEX IF NOT EXISTS idx_sessions_project ON sessions(project_path);
PRAGMA journal_mode = WAL;
EOF
```

### 2. Install the Claude Code hooks

Copy the hooks from `hooks/` to `~/.claude/hooks/`:

```bash
mkdir -p ~/.claude/hooks
cp hooks/*.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/*.sh
```

### 3. Configure Claude Code to use the hooks

Add to your `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [{ "command": "~/.claude/hooks/session-start.sh" }],
    "SessionEnd": [{ "command": "~/.claude/hooks/session-end.sh" }],
    "PreToolUse": [{ "command": "~/.claude/hooks/status-tracker.sh" }],
    "PostToolUse": [{ "command": "~/.claude/hooks/tool-tracker.sh" }]
  }
}
```

### 4. Build and run the app

Open `CommandCenter/CommandCenter.xcodeproj` in Xcode and build (Cmd+R).

## Codex CLI Integration (rollout watcher)

Codex does not yet expose Claude-style hooks, but its CLI writes rich session rollouts to
`~/.codex/sessions/**/rollout-*.jsonl`. OrbitDock watches those files **inside the app** using
native file events and maps them into the same SQLite schema.

**Notes:**
- The watcher keeps offsets in `~/.orbitdock/codex-rollout-state.json` to avoid double-counting.
- It only reacts to file changes (no polling/backfill), so old sessions appear only after new activity.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Command Center App                       │
│  ┌─────────────┐  ┌─────────────────────────────────────┐  │
│  │  Sidebar    │  │         Session Detail              │  │
│  │  - Sessions │  │  - Header (status, model, branch)   │  │
│  │  - Filter   │  │  - Stats (duration, cost, context)  │  │
│  │             │  │  - Conversation View                │  │
│  │             │  │  - Action Bar                       │  │
│  └─────────────┘  └─────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
                    ┌─────────────────┐
                    │  SQLite + WAL   │
                    │  ~/.claude/     │
                    │  dashboard.db   │
                    └─────────────────┘
                              ▲
                              │
         ┌────────────────────┼────────────────────┐
         │                    │                    │
    ┌────┴────┐         ┌────┴────┐         ┌────┴────┐
    │ Session │         │ Status  │         │  Tool   │
    │  Start  │         │ Tracker │         │ Tracker │
    │  Hook   │         │  Hook   │         │  Hook   │
    └─────────┘         └─────────┘         └─────────┘
```

## How It Works

1. **Hooks** - Claude Code triggers shell hooks at key events (session start/end, tool use)
2. **Database** - Hooks write session data to a SQLite database with WAL mode for concurrency
3. **File Monitoring** - The app watches the database file for changes using DispatchSource
4. **Transcript Parsing** - Conversations are read directly from Claude's JSONL transcript files
5. **Real-time Updates** - UI updates automatically via file system monitoring and timers

## Project Structure

```
CommandCenter/
├── CommandCenterApp.swift    # App entry point
├── ContentView.swift         # Main NavigationSplitView
├── Theme.swift               # Dark mode color definitions
├── Info.plist                # App permissions (AppleEvents)
├── Database/
│   └── DatabaseManager.swift # SQLite connection and queries
├── Models/
│   ├── Session.swift         # Session data model
│   ├── Activity.swift        # Activity event model
│   └── TranscriptMessage.swift # Chat message model
├── Services/
│   ├── TranscriptParser.swift  # JSONL transcript parsing
│   ├── NotificationManager.swift # macOS notifications
│   └── UsageManager.swift      # Token/cost tracking
└── Views/
    ├── SessionRowView.swift    # Sidebar row component
    ├── SessionDetailView.swift # Main detail view
    ├── ConversationView.swift  # Chat UI with animations
    └── MenuBarView.swift       # Menu bar extra (optional)
```

## Permissions

The app requires **Automation** permission to control iTerm2 for the "Focus" feature. Grant this in:

`System Settings → Privacy & Security → Automation → Command Center → iTerm`

## License

MIT
