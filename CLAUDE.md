# Claude Code Instructions for OrbitDock

## Project Overview

OrbitDock is a native macOS SwiftUI app - mission control for AI coding agents. It monitors sessions from multiple providers (Claude Code, Codex CLI), displaying them as spacecraft docked at your cosmic harbor. Reads from a SQLite database populated by a Swift CLI (Claude) and native FSEvents watchers (Codex) with real-time session tracking.

## Tech Stack

- **SwiftUI** - macOS 14+ with NavigationSplitView
- **SQLite.swift** - Database access via SPM package
- **SQLite WAL mode** - Enables concurrent reads/writes from CLI and app
- **Swift Argument Parser** - CLI subcommands
- **DispatchSource** - File system monitoring for live updates

## Key Patterns

### State Management
- Use `@State private var cache: [String: T] = [:]` dictionaries keyed by session/path ID to prevent state bleeding between sessions
- Always guard async callbacks with `guard currentId == targetId else { return }`

### Database Concurrency
- All SQLite connections MUST use WAL mode: `PRAGMA journal_mode = WAL`
- Set busy timeout: `PRAGMA busy_timeout = 5000`
- This applies to both the Swift app AND the CLI

### Animations
- Use `.spring(response: 0.35, dampingFraction: 0.8)` for message animations
- Add `.transition()` modifiers to ForEach items for smooth insertions
- Avoid timers for animations - use SwiftUI's declarative animation system

### Keyboard Navigation
- Dashboard and QuickSwitcher support keyboard navigation
- Use `KeyboardNavigationModifier` for arrow keys + Emacs bindings (C-n/p, C-a/e)
- Pattern: `@State selectedIndex` + `ScrollViewReader` for auto-scroll
- Selection highlight: cyan accent bar + `Color.accent.opacity(0.15)` background

### Toast Notifications
- `ToastManager` shows non-intrusive toasts when sessions need attention
- Triggers on `.permission` or `.question` status transitions
- Only shows when viewing a different session
- Auto-dismisses after 5 seconds, max 3 visible
- Key files: `ToastManager.swift`, `ToastView.swift`

### Cosmic Harbor Theme
- Use custom colors from Theme.swift - deep space backgrounds with nebula undertones
- `Color.backgroundPrimary` (void black), `Color.backgroundSecondary` (nebula purple), etc.
- `Color.accent` is the cyan orbit ring - use for active states, links, working sessions
- Status colors (5 distinct states):
  - `.statusWorking` (cyan) - Claude actively processing
  - `.statusPermission` (coral) - Needs tool approval - URGENT
  - `.statusQuestion` (purple) - Claude asked something - URGENT
  - `.statusReply` (soft blue) - Awaiting your next prompt
  - `.statusEnded` (gray) - Session finished
- All backgrounds should use theme colors, not system defaults
- Never use system colors (.blue, .green, .purple) - use themed equivalents

## File Locations

- **Database**: `~/.orbitdock/orbitdock.db` (separate from CLIs to survive reinstalls)
- **CLI Logs**: `~/.orbitdock/cli.log` (debug output from orbitdock-cli)
- **Migrations**: `migrations/` (numbered SQL files, e.g., `001_initial.sql`)
- **CLI Source**: `CommandCenter/OrbitDockCore/` (Swift Package with shared code + CLI)
- **Claude Transcripts**: `~/.claude/projects/<project-hash>/<session-id>.jsonl` (read-only)
- **Codex Sessions**: `~/.codex/sessions/**/rollout-*.jsonl` (read-only, watched via FSEvents)
- **Codex Watcher State**: `~/.orbitdock/codex-rollout-state.json` (offset tracking)

## OrbitDockCore Package

The CLI and shared database code live in a local Swift Package:

```
CommandCenter/OrbitDockCore/
├── Package.swift
└── Sources/
    ├── OrbitDockCore/          # Shared library
    │   ├── Database/           # CLIDatabase, SessionOperations (includes migrations)
    │   ├── Git/                # GitOperations (branch detection)
    │   └── Models/             # Input structs, enums
    └── OrbitDockCLI/           # CLI executable
        ├── CLI.swift           # Entry point with ArgumentParser
        └── Commands/
            ├── SessionStartCommand.swift
            ├── SessionEndCommand.swift
            ├── StatusTrackerCommand.swift
            ├── ToolTrackerCommand.swift
            └── SubagentTrackerCommand.swift
```

### CLI Commands
| Command | Hooks Handled | Purpose |
|---------|---------------|---------|
| `session-start` | SessionStart | Create session, capture model/source/permission_mode/agent_type |
| `session-end` | SessionEnd | Mark session ended with reason |
| `status-tracker` | UserPromptSubmit, Stop, Notification, PreCompact | Status transitions, first_prompt, compaction tracking |
| `tool-tracker` | PreToolUse, PostToolUse, PostToolUseFailure | Tool usage, permission state clearing |
| `subagent-tracker` | SubagentStart, SubagentStop | Track spawned agents (Explore, Plan, etc.) |

All commands read JSON from stdin (provided by Claude Code hooks).
All commands log to `~/.orbitdock/cli.log` for debugging.

## Database Migrations

Schema changes use a migration system with version tracking.

### Adding a new migration
1. Create `migrations/NNN_description.sql` (next number in sequence)
2. Write your SQL (CREATE TABLE, ALTER TABLE, etc.)
3. Update `Session.swift` model if adding session fields
4. Update `DatabaseManager.swift` column definitions and queries
5. Update `CLIDatabase.swift` if CLI needs to write the field

Migrations run automatically when:
- CLI executes (MigrationRunner in OrbitDockCore)
- Swift app starts (MigrationManager in DatabaseManager.swift)

### Legacy database handling
Existing databases without `schema_versions` table are automatically bootstrapped - migration 001 is marked as applied and any missing columns are added.

### Message Storage Architecture
The app uses a two-layer architecture for message display:

1. **JSONL Transcripts** (source of truth) - Claude writes here
2. **SQLite MessageStore** (read layer) - App reads from here for fast UI

Flow:
- File change detected → EventBus debounces (300ms)
- TranscriptParser.parseAll() reads JSONL once
- MessageStore.syncFromParseResult() stores in SQLite
- UI reads from SQLite (~50ms for 1000+ messages)

Key files:
- `MessageStore.swift` - SQLite storage with per-session sync locks
- `TranscriptParser.swift` - JSONL parsing with in-memory cache
- `EventBus.swift` - Debounced event coordination

### Parsing transcript data
- Use `TranscriptParser.parseAll()` for unified single-pass parsing
- Returns messages, stats, lastUserPrompt, and lastTool in one call
- Messages have `type` field: "human", "assistant", "tool_use", "tool_result"
- Token usage is in assistant messages under `message.usage`

### AppleScript for iTerm2
- Requires `NSAppleEventsUsageDescription` in Info.plist
- Use `NSAppleScript(source:)` with `executeAndReturnError`
- iTerm2 sessions have `unique ID` and `path` properties

### Multi-Provider Usage APIs

**Claude** (`SubscriptionUsageService.swift`):
- Fetches from `api.anthropic.com/api/oauth/usage`
- Reads OAuth token from Claude CLI keychain (`Claude Code-credentials`)
- Caches token in app's own keychain (`com.orbitdock.claude-token`) to avoid prompts
- Auto-refreshes every 60 seconds
- Tracks: 5h session window, 7d rolling window

**Codex** (`CodexUsageService.swift`):
- Fetches from Codex app server API
- Primary and secondary rate limit windows
- Token-based usage tracking

**Unified Access** (`UsageServiceRegistry.swift`):
- Coordinates all provider services
- `activeProviders` returns providers with valid data
- `windows(for: .claude)` or `windows(for: .codex)` for rate limit windows

Key UI files:
- `Views/Usage/` - Provider usage gauges, bars, and badges

## Testing Changes

1. Make changes to Swift code
2. Build in Xcode (Cmd+R)
3. For Claude: Start a new Claude Code session to trigger hooks
4. For Codex: Start a Codex session (or modify an existing rollout file)
5. Verify data appears in OrbitDock

### Testing CLI changes
```bash
cd CommandCenter/OrbitDockCore
swift build
echo '{"session_id":"test","cwd":"/tmp"}' | .build/debug/orbitdock-cli session-start
```

## Don't

- Don't use `.foregroundColor(.tertiary)` - use `.foregroundStyle(.tertiary)` instead
- Don't use `.scaleEffect()` on ProgressView - use `.controlSize(.small)` instead
- Don't use timers for animations - use SwiftUI animation modifiers
- Don't store single @State values for data that varies by session - use dictionaries
- Don't use system colors (.blue, .green, .purple, .orange) - use `Color.accent`, `Color.statusWorking`, etc.
- Don't use generic gray backgrounds - use the cosmic palette (`Color.backgroundPrimary`, etc.)
