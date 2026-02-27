# Claude Code Instructions for OrbitDock

## Project Overview

OrbitDock is a native SwiftUI app for macOS and iOS — mission control for AI coding agents. A Rust server (`orbitdock-server`) is the central hub: it owns the SQLite database, receives events from Claude Code hooks via HTTP POST (`/api/hook`), manages Codex sessions via codex-core, and serves real-time updates to clients over WebSocket.

## Tech Stack

- **SwiftUI** - macOS 14+ with NavigationSplitView
- **Rust / Axum** - orbitdock-server (session management, persistence, WebSocket + HTTP)
- **rusqlite + SQLite WAL** - Database access, concurrent reads/writes
- **Shell hook script** - `~/.orbitdock/hook.sh` forwards Claude Code hooks via HTTP POST
- **codex-core** - Embedded Codex runtime for direct sessions

## Build, Test, and Lint Commands

```bash
# From repo root
make build            # Build macOS app (xcbeautify output)
make build-ios        # Build iOS app
make build-all        # Build both macOS and iOS
make test-unit        # Run unit tests only (OrbitDockTests)
make test-ui          # Run UI tests only (OrbitDockUITests)
make test-all         # Run both unit + UI tests
make rust-build       # Build orbitdock-server
make rust-check       # Check Rust workspace
make rust-test        # Run Rust workspace tests
make rust-ci          # fmt + clippy + tests
make rust-fmt         # Format Rust workspace
make rust-fmt-check   # Validate Rust formatting
make rust-lint        # Clippy with warnings denied
make rust-run         # Run orbitdock-server in dev mode
make rust-run-debug   # Run orbitdock-server with debug logs
make rust-env         # Print active Rust cache/build env
make rust-size        # Inspect Rust cache disk usage
make rust-clean-incremental # Remove incremental caches only
make rust-clean-debug # Remove dev/test artifacts only
make rust-clean-sccache # Clear local sccache files
make rust-clean-release # Clean Rust release artifacts only
make release          # Build + package macOS server release zip
make rust-release-linux # Build + package Linux server release zip
make fmt              # Format Swift + Rust
make lint             # Lint Swift + Rust
```

`make test-unit` intentionally excludes UI tests so local unit-test runs do not trigger the UI automation flow.

Rust workflow policy (required): use `make rust-*` targets for normal development.

Do not run plain `cargo` commands unless you are adding or fixing a Make target; plain cargo can bypass repo cache settings and create duplicate `target` directories.

If a Rust command is missing, add it to `Makefile` first and then run it via `make`.

## Key Patterns

### Server-Authoritative State
- The Rust server is the **single source of truth** for all session and approval state. Clients (Swift app) should never derive, infer, or reconcile business-logic state locally — they receive it from the server via WebSocket events and display it.
- Never add client-side logic that scans history or computes queue heads. If the server doesn't provide the data the client needs, fix the server to emit it.
- Prefer functional, stateless transforms on the server side (its own state machine drives transitions). The client's job is rendering, not reasoning about state.

### Approval Version Gating
- Each session has a monotonic `approval_version` counter (`sessions.approval_version` in SQLite, `SessionHandle.approval_version` in memory)
- The counter increments on every approval state change: enqueue, decide, clear, or in-place update
- Every approval-related message includes the version: `ApprovalRequested`, `SessionDelta` (when `pending_approval` changes), and `ApprovalDecisionResult`
- Clients compare the incoming version against their local high-water mark (`SessionObservable.approvalVersion`) and reject stale events
- The `approval_version` field is `Option<u64>` for backwards compatibility with older servers — `nil` bypasses the gate
- Key files: `session.rs` (queue + version management), `codex_session.rs` (`inject_approval_version`), `transition.rs` (state machine), `ServerAppState.swift` (`handleApprovalRequested`, `handleApprovalDecisionResult`)

### State Management
- Use `@State private var cache: [String: T] = [:]` dictionaries keyed by session/path ID to prevent state bleeding between sessions
- Always guard async callbacks with `guard currentId == targetId else { return }`

### Database Concurrency
- The Rust server (`persistence.rs`) is the sole SQLite writer
- All connections use WAL mode (`journal_mode = WAL`), `busy_timeout = 5000`, `synchronous = NORMAL`
- The migration runner sets these pragmas at startup

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

## Server Setup Flow

The app doesn't embed the server — it connects over WebSocket. Endpoint configuration is multi-server and persisted in `ServerEndpointSettings`/`ServerEndpointStore`.

On launch, `ServerManager` still checks local install state for onboarding, while `ServerRuntimeRegistry` manages active endpoint runtimes and connection state:

1. **Health check** `localhost:4000/health` → `.running` (covers `make rust-run`, brew, launchd)
2. **Launchd plist** at `~/Library/LaunchAgents/com.orbitdock.server.plist` → `.installed` (stopped)
3. **Configured endpoints** in `ServerEndpointSettings` are loaded and connected by runtime registry
4. Otherwise → `.notConfigured` (shows `ServerSetupView`)

`ServerManager` shells out to the server's own CLI for install/service management — no custom plist generation in Swift.

### Key Files
- `Services/Server/ServerManager.swift` — Install state detection, CLI wrapper (refreshState, install, startService, stopService)
- `Views/ServerSetupView.swift` — First-launch onboarding (Install Locally / Connect to Remote)
- `Services/Server/ServerEndpointSettings.swift` — Multi-endpoint settings façade
- `Services/Server/ServerEndpointStore.swift` — Endpoint persistence + legacy migration
- `Services/Server/ServerRuntimeRegistry.swift` — Endpoint-scoped runtime orchestration + control-plane selection
- `Platform/PlatformPaths.swift` — `orbitDockBinDirectory` (`~/.orbitdock/bin/`)

### Install Flow (triggered from ServerSetupView or Settings)
1. Find binary (Bundle Resources → env var → `~/.orbitdock/bin/` → PATH)
2. Copy to `~/.orbitdock/bin/` if from bundle
3. `orbitdock-server init`
4. `orbitdock-server install-hooks`
5. `orbitdock-server install-service --enable`
6. Wait for health check → connect WebSocket

### Development
In dev, run `make rust-run` — the app detects it via health check and skips setup. Set `ORBITDOCK_SERVER_PATH` in Xcode scheme to test the install flow with a debug binary.

## File Locations

All server paths are resolved via `paths.rs` from a single data directory (`--data-dir` / `ORBITDOCK_DATA_DIR` / `~/.orbitdock`).

- **Server Binary**: `~/.orbitdock/bin/orbitdock-server` (installed by app) or on PATH
- **Database**: `<data_dir>/orbitdock.db` (separate from CLIs to survive reinstalls)
- **PID File**: `<data_dir>/orbitdock.pid` (written after bind, removed on shutdown)
- **Auth Token**: `<data_dir>/auth-token` (optional, 0600 permissions)
- **Encryption Key**: `<data_dir>/encryption.key` (auto-generated, 0600 permissions — see "Config Encryption" below)
- **Launchd Plist**: `~/Library/LaunchAgents/com.orbitdock.server.plist` (created by `install-service`)
- **CLI Logs**: `~/.orbitdock/cli.log` (debug output from orbitdock-cli)
- **Codex App Logs**: `<data_dir>/logs/codex.log` (structured JSON logs for Codex debugging)
- **Rust Server Logs**: `<data_dir>/logs/server.log` (structured JSON logs from orbitdock-server)
- **Migrations**: `migrations/` (SQL files embedded in binary via `include_str!`)
- **Hook Script**: `scripts/hook.sh` (dev source) / `scripts/hook.sh.template` (standalone template) / `<data_dir>/hook.sh` (installed)
- **Shared Models**: `OrbitDock/OrbitDockCore/` (Swift Package with shared code)
- **Claude Transcripts**: `~/.claude/projects/<project-hash>/<session-id>.jsonl` (read-only)
- **Codex Sessions**: `~/.codex/sessions/**/rollout-*.jsonl` (read-only, watched via FSEvents)
- **Codex Watcher State**: `<data_dir>/codex-rollout-state.json` (offset tracking)
- **Hook Event Spool**: `<data_dir>/spool/` (queued hook events when server is offline, drained on startup)
- **Timeline Logs**: `<data_dir>/logs/timeline.log` (macOS) / `timeline-ios.log` (iOS) — conversation view height calculations and overflow detection
- **Claude Agent SDK**: `orbitdock-server/docs/node_modules/@anthropic-ai/claude-agent-sdk/` — reference SDK for protocol reverse-engineering
- **Claude Protocol Docs**: `orbitdock-server/docs/claude-agent-sdk-protocol.md` — stdin/stdout JSON protocol reference

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
make rust-run-debug
RUST_LOG=debug make rust-run
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

## Debugging Conversation Timeline

Both platforms log height calculations and overflow detection to a plain-text file via `TimelineFileLogger`. The file truncates on each app launch.

### Log Location
- macOS: `~/.orbitdock/logs/timeline.log`
- iOS: `~/.orbitdock/logs/timeline-ios.log`

### Viewing Logs
```bash
# Watch live
tail -f ~/.orbitdock/logs/timeline.log

# Check for height overflow (content exceeds calculated bounds — causes clipping)
grep "OVERFLOW" ~/.orbitdock/logs/timeline.log

# Filter by message ID
grep "e84dd5b4" ~/.orbitdock/logs/timeline.log

# Filter by cell type
grep "tool-cell" ~/.orbitdock/logs/timeline.log
grep "rich\[" ~/.orbitdock/logs/timeline.log
```

### What Gets Logged
- **`requiredHeight`**: Height calculation breakdown (header, content, total, width) for every expanded tool card and rich message cell
- **`tool-cell`** / **`rich`**: Configure-time frame values and max subview bottom position
- **`⚠️ OVERFLOW`**: Content exceeds calculated height — the root cause of visual clipping. Includes the exact overflow amount, cell type, message ID, and all dimensions

### Key Files
- `TimelineFileLogger.swift` — `TimelineFileLogger` singleton (shared by both platforms)
- `ConversationCollectionView+macOS.swift` — macOS `heightOfRow`, `viewFor` logging
- `ConversationCollectionView+iOS.swift` — iOS `sizeForItemAt` logging
- `ExpandedToolCellView.swift` — Expanded tool card height calc + overflow detection
- `Markdown/NativeRichMessageCellView.swift` — Rich message height calc + overflow detection

## OrbitDockCore Package

Shared Swift models used by the SwiftUI app. No CLI — hooks go directly via HTTP POST.

```
OrbitDock/OrbitDockCore/
├── Package.swift
└── Sources/
    └── OrbitDockCore/          # Shared library
        └── Models/             # Input structs, enums (WorkStatus, SessionStatus, etc.)
```

### Hook Script

Claude Code hooks pipe JSON to `~/.orbitdock/hook.sh <type>`, which injects the `type` field and POSTs to `http://127.0.0.1:4000/api/hook`. Source lives at `scripts/hook.sh` (dev) and `scripts/hook.sh.template` (standalone deploy with `{{SERVER_URL}}`, `{{SPOOL_DIR}}`, `{{AUTH_HEADER}}` placeholders).

Install hooks automatically: `orbitdock-server install-hooks`

| Claude Hook | Type Argument |
|---|---|
| `SessionStart` | `claude_session_start` |
| `SessionEnd` | `claude_session_end` |
| `UserPromptSubmit`, `Stop`, `Notification`, `PreCompact` | `claude_status_event` |
| `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PermissionRequest` | `claude_tool_event` |
| `SubagentStart`, `SubagentStop` | `claude_subagent_event` |

### Server CLI

The server binary is self-contained with subcommands for standalone deployment:

```bash
orbitdock-server init                    # Bootstrap dirs, DB, hook script
orbitdock-server install-hooks           # Merge hooks into ~/.claude/settings.json
orbitdock-server start [--bind ADDR]     # Start server (default: 127.0.0.1:4000)
orbitdock-server install-service --enable # Generate launchd/systemd service
orbitdock-server status                  # Check if running
orbitdock-server generate-token          # Create auth token
```

Global `--data-dir` overrides all paths. All data paths resolved via `paths.rs` module.

## Database Migrations

Migrations are **embedded in the binary** via `include_str!` in `migration_runner.rs` — no filesystem access needed at runtime.

### Adding a new migration
1. Create `migrations/NNN_description.sql` (next number after baseline: 002+)
2. Write your SQL (CREATE TABLE, ALTER TABLE, etc.)
3. Add the `include_str!` entry in `migration_runner.rs` `EMBEDDED_MIGRATIONS` array
4. Update `persistence.rs` — add PersistCommand variant and handler
5. Update `RestoredSession` / load queries if adding session fields
6. Update protocol types in `orbitdock-protocol` crate if field needs to reach the Swift app

Migrations run when: Rust server starts (`migration_runner::run_migrations` in `main.rs`)

### Message Storage Architecture

- Rust server receives events via WebSocket (CLI) or codex-core (Codex)
- `persistence.rs` batches writes through PersistCommand channel
- Messages stored in SQLite `messages` table
- Swift app receives messages in real-time via WebSocket — does NOT read SQLite directly

## Database Conventions

### Single writer: the Rust server
Only `orbitdock-server` reads from and writes to SQLite. The Swift app and CLI
never touch the database directly. All data flows through WebSocket.

### Data flow
```
Claude hooks → HTTP POST /api/hook → Rust server (port 4000) → SQLite
                                           ↓ WebSocket
                                     Swift app (read-only client)
```

### Schema changes
1. Add a numbered migration in `migrations/` (currently 001–008)
2. Add `include_str!` entry in `migration_runner.rs` `EMBEDDED_MIGRATIONS` array
3. Use `IF NOT EXISTS` for safety
4. Add the corresponding PersistCommand in `persistence.rs`
5. Update protocol types if the field needs to reach the Swift app
6. Run `make rust-test` to verify

### Tables
| Table | Purpose |
|-------|---------|
| `sessions` | Core session tracking — one row per Claude/Codex session. Includes `pending_approval_id` (queue head) and `approval_version` (monotonic counter for client gating) |
| `messages` | Conversation messages per session |
| `subagents` | Spawned Task agents (Explore, Plan, etc.) |
| `turn_diffs` | Per-turn git diff snapshots + token usage |
| `approval_history` | Tool approval requests and decisions |
| `review_comments` | Code review annotations for workbench |
| `config` | Key-value settings (API keys stored encrypted) |
| `schema_versions` | Migration tracking |

### Key files
- `orbitdock-server/crates/server/src/paths.rs` — Central path resolution (data dir, db, logs, spool, etc.)
- `orbitdock-server/crates/server/src/persistence.rs` — All CRUD operations
- `orbitdock-server/crates/server/src/migration_runner.rs` — Embedded migrations via `include_str!`
- `orbitdock-server/crates/server/src/websocket.rs` — WebSocket protocol
- `orbitdock-server/crates/server/src/hook_handler.rs` — HTTP POST `/api/hook` endpoint for Claude Code hooks
- `orbitdock-server/crates/server/src/crypto.rs` — AES-256-GCM encryption for config secrets
- `orbitdock-server/crates/server/src/auth.rs` — Optional Bearer token middleware
- `orbitdock-server/crates/protocol/` — Shared types between server components
- `migrations/001_baseline.sql` — Complete schema definition
- `migrations/008_approval_version.sql` — Adds `approval_version` column to `sessions`
- `scripts/hook.sh` — Dev-time hook script
- `scripts/hook.sh.template` — Templated hook script for standalone deploy

### Config Encryption

Sensitive values in the `config` table (like the OpenAI API key) are encrypted at rest with AES-256-GCM via the `ring` crate.

**How it works:** `persistence.rs` calls `crypto::encrypt()` before writing to the `config` table. `load_config_value()` calls `crypto::decrypt()` on read. Encrypted values get an `enc:` prefix — plaintext values without the prefix pass through unchanged, so no migration is needed for existing data.

**Key resolution order:**
1. `ORBITDOCK_ENCRYPTION_KEY` env var (base64-encoded 32 bytes)
2. `<data_dir>/encryption.key` file (raw 32 bytes, 0600 permissions)
3. Auto-generated on first `ensure_key()` call (startup + `init`)

**If the key is lost**, any `enc:` prefixed values become unrecoverable. The server logs an ERROR when it can't decrypt.

**Key files:** `crypto.rs` (encrypt/decrypt + key management), `paths.rs` (`encryption_key_path()`), `persistence.rs` (transparent encrypt on write, decrypt on read)

### AppleScript for iTerm2
- Requires `NSAppleEventsUsageDescription` in Info.plist
- Use `NSAppleScript(source:)` with `executeAndReturnError`
- iTerm2 sessions have `unique ID` and `path` properties

### Multi-Provider Usage APIs

Usage is fetched through orbitdock-server over WebSocket RPCs and is scoped to the current control-plane endpoint selected on each client device.

**Claude** (`SubscriptionUsageService.swift`):
- Calls `fetch_claude_usage` on the selected control-plane endpoint
- Auto-refreshes every 60 seconds
- Tracks: 5h session window, 7d rolling window

**Codex** (`CodexUsageService.swift`):
- Calls `fetch_codex_usage` on the selected control-plane endpoint
- Tracks primary and secondary rate-limit windows

**Server-side usage RPCs**:
- Implemented in `orbitdock-server/crates/server/src/websocket.rs`
- Returned as `claude_usage_result` / `codex_usage_result`
- Requests from non-primary client claims are rejected with `not_control_plane_for_client`

**Unified Access** (`UsageServiceRegistry.swift`):
- Coordinates provider services
- Keeps provider cards visible even when usage requests fail, so auth/transport errors remain visible in UI
- `windows(for: .claude)` / `windows(for: .codex)` expose normalized rate-limit windows

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

### Testing hook script
```bash
# Test session start (server must be running on port 4000)
echo '{"session_id":"test","cwd":"/tmp","model":"claude-opus-4-6","source":"startup"}' \
  | ~/.orbitdock/hook.sh claude_session_start

# Test with curl directly
curl -s -X POST -H "Content-Type: application/json" \
  -d '{"type":"claude_session_start","session_id":"test","cwd":"/tmp"}' \
  http://127.0.0.1:4000/api/hook
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
