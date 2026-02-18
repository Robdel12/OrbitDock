# Claude Code Instructions for OrbitDock

## Project Overview

OrbitDock is a native macOS SwiftUI app - mission control for AI coding agents. It monitors sessions from multiple providers (Claude Code, Codex CLI), displaying them as spacecraft docked at your cosmic harbor. Reads from a SQLite database populated by a Swift CLI (Claude) and native FSEvents watchers (Codex) with real-time session tracking.

## Tech Stack

- **SwiftUI** - macOS 14+ with NavigationSplitView
- **SQLite.swift** - Database access via SPM package
- **SQLite WAL mode** - Enables concurrent reads/writes from CLI and app
- **Swift Argument Parser** - CLI subcommands
- **DispatchSource** - File system monitoring for live updates

## Build, Test, and Lint Commands

```bash
# From repo root
make build      # Build app (xcodebuild wrapper)
make test-unit  # Run unit tests only (OrbitDockTests)
make test-ui    # Run UI tests only (OrbitDockUITests)
make test-all   # Run both unit + UI tests
make rust-build # Build orbitdock-server
make rust-check # cargo check --workspace (orbitdock-server)
make rust-test  # cargo test --workspace (orbitdock-server)
make fmt        # Format Swift + Rust (swiftformat + cargo fmt)
make lint       # Lint Swift + Rust (swiftformat --lint + cargo clippy)
```

`make test-unit` intentionally excludes UI tests so local unit-test runs do not trigger the UI automation flow.

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
- Text hierarchy: `Color.textPrimary` / `.textSecondary` / `.textTertiary` / `.textQuaternary` — see "Text Contrast" section below
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
- **Codex App Logs**: `~/.orbitdock/logs/codex.log` (structured JSON logs for Codex debugging)
- **Rust Server Logs**: `~/.orbitdock/logs/server.log` (structured JSON logs from orbitdock-server)
- **Migrations**: `migrations/` (numbered SQL files, e.g., `001_initial.sql`)
- **CLI Source**: `OrbitDock/OrbitDockCore/` (Swift Package with shared code + CLI)
- **Claude Transcripts**: `~/.claude/projects/<project-hash>/<session-id>.jsonl` (read-only)
- **Codex Sessions**: `~/.codex/sessions/**/rollout-*.jsonl` (read-only, watched via FSEvents)
- **Codex Watcher State**: `~/.orbitdock/codex-rollout-state.json` (offset tracking)

## Debugging Codex Integration

The Codex integration writes structured JSON logs for debugging. Each log entry is a single JSON line.

### Log Location
`~/.orbitdock/logs/codex.log` (auto-rotates at 10MB)

### Viewing Logs
```bash
# Watch live events
tail -f ~/.orbitdock/logs/codex.log | jq .

# Filter by level
tail -f ~/.orbitdock/logs/codex.log | jq 'select(.level == "error")'

# Filter by category
tail -f ~/.orbitdock/logs/codex.log | jq 'select(.category == "event")'
tail -f ~/.orbitdock/logs/codex.log | jq 'select(.category == "decode")'
tail -f ~/.orbitdock/logs/codex.log | jq 'select(.category == "bridge")'

# Filter by session
tail -f ~/.orbitdock/logs/codex.log | jq 'select(.sessionId == "codex-direct-abc123")'

# Show only specific events
tail -f ~/.orbitdock/logs/codex.log | jq 'select(.message | contains("item/"))'
```

### Log Categories
- `event` - Codex app-server events (turn/started, item/created, etc.)
- `connection` - Connection lifecycle (connecting, connected, disconnected)
- `message` - MessageStore operations (append, update, upsert)
- `bridge` - MCP Bridge HTTP requests/responses
- `decode` - JSON decode failures with raw payloads
- `session` - Session lifecycle (create, send, approve)

### Log Levels
- `debug` - Verbose details (streaming events, minor updates)
- `info` - Normal operations (turn started, message sent)
- `warning` - Approval requests, unknown events
- `error` - Decode failures, connection errors

### Example Log Entry
```json
{
  "ts": "2024-01-15T10:30:45.123Z",
  "level": "info",
  "category": "event",
  "message": "item/created",
  "sessionId": "codex-direct-abc123",
  "data": {
    "itemId": "item_xyz",
    "itemType": "commandExecution",
    "status": "inProgress"
  }
}
```

### Decode Error Debugging
When JSON decode fails, logs include the raw JSON:
```bash
tail -100 ~/.orbitdock/logs/codex.log | jq 'select(.category == "decode")'
```

This shows the exact payload that failed to parse, making it easy to fix struct definitions.

## Debugging Rust Server

The Rust server (`orbitdock-server`) logs to a file only — no stderr output. All logs are structured JSON.

### Log Location
`~/.orbitdock/logs/server.log`

### Viewing Logs
```bash
# Watch all server logs live
tail -f ~/.orbitdock/logs/server.log | jq .

# Filter by structured event name
tail -f ~/.orbitdock/logs/server.log | jq 'select(.event == "session.resume.connector_failed")'

# Filter by component
tail -f ~/.orbitdock/logs/server.log | jq 'select(.component == "websocket")'

# Filter by session/request IDs
tail -f ~/.orbitdock/logs/server.log | jq 'select(.session_id == "your-session-id")'
tail -f ~/.orbitdock/logs/server.log | jq 'select(.request_id == "your-request-id")'

# Errors only
tail -f ~/.orbitdock/logs/server.log | jq 'select(.level == "ERROR")'

# Filter by source file
tail -f ~/.orbitdock/logs/server.log | jq 'select(.filename | strings | test("codex"))'
```

### Verbose Debug Logs
Default log level is `info`. For verbose output, set `ORBITDOCK_SERVER_LOG_FILTER` (or `RUST_LOG`) before launching:
```bash
ORBITDOCK_SERVER_LOG_FILTER=debug cargo run -p orbitdock-server
RUST_LOG=debug cargo run -p orbitdock-server
```

### Log Controls
- `ORBITDOCK_SERVER_LOG_FILTER` - optional tracing filter override (for example `debug,tower_http=warn`).
- `ORBITDOCK_SERVER_LOG_FORMAT` - `json` (default) or `pretty`.
- `ORBITDOCK_TRUNCATE_SERVER_LOG_ON_START=1` - truncates `server.log` on boot.

### Structured Fields
Core event fields are stable for filtering:
- `event`, `component`, `session_id`, `request_id`, `connection_id`, `error`

### Key Log Sources
- `crates/server/src/main.rs` - Startup, session restoration
- `crates/server/src/websocket.rs` - WebSocket messages, session creation
- `crates/server/src/persistence.rs` - SQLite writes, batch flushes
- `crates/server/src/codex_session.rs` - Codex event handling, approvals
- `crates/connectors/src/codex.rs` - codex-core events, message translation

## OrbitDockCore Package

The CLI and shared database code live in a local Swift Package:

```
OrbitDock/OrbitDockCore/
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

## OrbitDock MCP

An MCP for pair-debugging Codex sessions. Allows Claude to interact with the **same** Codex session visible in OrbitDock - sending messages and handling approvals.

### Architecture

```
MCP (Node.js)  →  HTTP :19384  →  OrbitDock (MCPBridge)  →  Codex app-server
```

The MCP routes through OrbitDock's HTTP bridge to `CodexDirectSessionManager`. Same session, no state sync issues.

### Available Tools

| Tool | Description |
|------|-------------|
| `list_sessions` | List active Codex sessions that can be controlled |
| `send_message` | Send a user prompt to a Codex session (starts a turn) |
| `interrupt_turn` | Stop the current turn |
| `approve` | Approve/reject pending tool executions |
| `check_connection` | Verify OrbitDock bridge is running |

### Debugging via CLI

For database queries and log inspection, use CLI tools directly:

```bash
# Query the database
sqlite3 ~/.orbitdock/orbitdock.db "SELECT id, work_status FROM sessions WHERE provider='codex'"

# Watch Codex logs live (JSON format)
tail -f ~/.orbitdock/logs/codex.log | jq .

# Filter logs by error level
tail -f ~/.orbitdock/logs/codex.log | jq 'select(.level == "error" or .level == "warning")'

# See MCP bridge requests
tail -f ~/.orbitdock/logs/codex.log | jq 'select(.category == "bridge")'
```

### Key Files

- `orbitdock-debug-mcp/` - Node.js MCP server
- `MCPBridge.swift` - OrbitDock's HTTP server on port 19384
- `.mcp.json` - Project MCP configuration

### Requirements

- **OrbitDock must be running** - MCPBridge starts automatically on port 19384

## Testing Changes

1. Make changes to Swift code
2. Build with `make build` (or Xcode Cmd+R when needed)
3. Run `make test-unit` for normal local verification
4. Run `make test-ui` when UI coverage is required
5. Run `make lint` before handing off changes
6. For Claude: Start a new Claude Code session to trigger hooks
7. For Codex: Start a Codex session (or modify an existing rollout file)
8. Verify data appears in OrbitDock

### Testing CLI changes
```bash
cd OrbitDock/OrbitDockCore
swift build
echo '{"session_id":"test","cwd":"/tmp"}' | .build/debug/orbitdock-cli session-start
```

## Text Contrast — Design System

**NEVER use SwiftUI's hierarchical `.foregroundStyle(.tertiary)` or `.foregroundStyle(.quaternary)`** — they resolve to ~30%/~20% opacity which is invisible on our dark backgrounds.

Always use the explicit themed `Color` values defined in `Theme.swift`:

| Token | Opacity | Use for |
|-------|---------|---------|
| `Color.textPrimary` | 92% | Headings, session names, key data values |
| `Color.textSecondary` | 65% | Labels, supporting text, active descriptions |
| `Color.textTertiary` | 50% | Meta info, timestamps, counts, monospaced data |
| `Color.textQuaternary` | 38% | Lowest priority but still readable (hints, separators) |

For `.foregroundStyle(.primary)` and `.foregroundStyle(.secondary)`, SwiftUI's built-in values are acceptable because they have enough contrast. But `.tertiary` and `.quaternary` must always use the explicit Color values above.

## Don't

- Don't use `.foregroundStyle(.tertiary)` or `.foregroundStyle(.quaternary)` — use `Color.textTertiary` / `Color.textQuaternary` instead
- Don't use `.foregroundColor()` at all — use `.foregroundStyle()` with themed Color values
- Don't use `.scaleEffect()` on ProgressView - use `.controlSize(.small)` instead
- Don't use timers for animations - use SwiftUI animation modifiers
- Don't store single @State values for data that varies by session - use dictionaries
- Don't use system colors (.blue, .green, .purple, .orange) - use `Color.accent`, `Color.statusWorking`, etc.
- Don't use generic gray backgrounds - use the cosmic palette (`Color.backgroundPrimary`, etc.)
