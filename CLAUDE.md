# Claude Code Instructions for Command Center

## Project Overview

Command Center is a native macOS SwiftUI app that monitors Claude Code CLI sessions. It reads from a SQLite database populated by Claude Code hooks and displays real-time session information.

## Tech Stack

- **SwiftUI** - macOS 14+ with NavigationSplitView
- **SQLite.swift** - Database access via SPM package
- **SQLite WAL mode** - Enables concurrent reads/writes from hooks
- **DispatchSource** - File system monitoring for live updates

## Key Patterns

### State Management
- Use `@State private var cache: [String: T] = [:]` dictionaries keyed by session/path ID to prevent state bleeding between sessions
- Always guard async callbacks with `guard currentId == targetId else { return }`

### Database Concurrency
- All SQLite connections MUST use WAL mode: `PRAGMA journal_mode = WAL`
- Set busy timeout: `PRAGMA busy_timeout = 5000`
- This applies to both the Swift app AND all bash hooks

### Animations
- Use `.spring(response: 0.35, dampingFraction: 0.8)` for message animations
- Add `.transition()` modifiers to ForEach items for smooth insertions
- Avoid timers for animations - use SwiftUI's declarative animation system

### Dark Theme
- Use custom colors from Theme.swift: `Color.backgroundPrimary`, `Color.backgroundSecondary`, etc.
- All backgrounds should use these colors, not system defaults

## File Locations

- **Database**: `~/.claude/dashboard.db`
- **Hooks**: `~/.claude/hooks/` (session-start.sh, session-end.sh, status-tracker.sh, tool-tracker.sh)
- **Transcripts**: `~/.claude/projects/<project-hash>/<session-id>.jsonl`

## Common Tasks

### Adding a new session field
1. Add column to SQLite: `ALTER TABLE sessions ADD COLUMN field_name TYPE`
2. Update `Session.swift` model
3. Update `DatabaseManager.swift` column definition and fetchSessions query
4. Update relevant hook to write the field

### Parsing transcript data
- Use `TranscriptParser.swift` for reading JSONL files
- Messages have `type` field: "human", "assistant", "tool_use", "tool_result"
- Token usage is in assistant messages under `message.usage`

### AppleScript for iTerm2
- Requires `NSAppleEventsUsageDescription` in Info.plist
- Use `NSAppleScript(source:)` with `executeAndReturnError`
- iTerm2 sessions have `unique ID` and `path` properties

## Testing Changes

1. Make changes to Swift code
2. Build in Xcode (Cmd+R)
3. Start a new Claude Code session to trigger hooks
4. Verify data appears in Command Center

## Don't

- Don't use `.foregroundColor(.tertiary)` - use `.foregroundStyle(.tertiary)` instead
- Don't use `.scaleEffect()` on ProgressView - use `.controlSize(.small)` instead
- Don't use timers for animations - use SwiftUI animation modifiers
- Don't store single @State values for data that varies by session - use dictionaries
