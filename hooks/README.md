# OrbitDock Hooks

These hooks integrate with Claude Code's lifecycle events to track AI coding sessions in real-time.

> **Note:** Codex CLI sessions are tracked via native FSEvents in the SwiftUI app (`CodexRolloutWatcher.swift`), not via hooks. These hooks are specifically for Claude Code integration.

## Why Hooks Matter

Without hooks, OrbitDock would be blind to Claude Code sessions. Hooks give us:

- **Real-time session tracking** - Know exactly when sessions start, end, and what's happening
- **Tool usage analytics** - See which tools Claude uses most, track command patterns
- **Attention states** - Know when Claude needs your input vs actively working
- **Prompt/tool counts** - Understand session complexity and engagement
- **Workstream linking** - Automatically connect sessions to git branches

## Hook Architecture

```
Claude Code Event → Hook Script → SQLite Database → OrbitDock App
                                        ↓
                              notifyutil (macOS)
                                        ↓
                              App refreshes UI
```

All hooks are **async** so they never block Claude Code. They write to SQLite with WAL mode for concurrent access, then notify the macOS app via `notifyutil`.

## The Hooks

### `session-start.js`
**Fires:** When Claude Code starts a new session or resumes an existing one

**Input fields:**
- `session_id`, `cwd`, `model`, `transcript_path`
- `source` - How the session started: `startup`, `resume`, `clear`, `compact`

**Tracks:**
- Session ID, project path, model
- Git branch and repo info
- Terminal session (for iTerm2 integration)
- Links session to workstream if on a feature branch

**Why it matters:** This creates the session record that everything else updates. Without it, we wouldn't know a session exists.

### `session-end.js`
**Fires:** When a Claude Code session ends

**Input fields:**
- `session_id`, `cwd`
- `reason` - Why the session ended: `clear`, `logout`, `prompt_input_exit`, `bypass_permissions_disabled`, `other`

**Tracks:**
- End timestamp
- Exit reason

**Why it matters:** Marks sessions as ended so the app can show accurate session states and calculate session durations.

### `status-tracker.js`
**Fires:** On multiple events - handles the session's "attention state"

| Event | What it does |
|-------|--------------|
| `UserPromptSubmit` | Increments prompt count, sets status to "working" |
| `Stop` | Sets status to "waiting", syncs session summary from Claude |
| `Notification` | Handles idle_prompt (waiting) and permission_prompt (needs permission) |

**Session naming:** On `Stop`, resolves the best available title using this priority:
1. Custom title (from `/rename` command)
2. Claude's summary from `sessions-index.json`
3. First user message (truncated to 60 chars)
4. Humanized slug (e.g., "Dapper Soaring Spindle")

This ensures sessions always have meaningful names in the UI.

**Why it matters:** This is how OrbitDock knows if Claude is working, waiting for your input, or blocked on permissions. The attention state drives the UI - showing which sessions need your attention.

### `tool-tracker.js`
**Fires:** Before, after, and on failure of every tool use

| Event | What it does |
|-------|--------------|
| `PreToolUse` | Records which tool is running, sets status to "working", captures question text for `AskUserQuestion` |
| `PostToolUse` | Increments tool count, clears `pending_tool_name` |
| `PostToolUseFailure` | Clears pending state (fixes state after permission denial), increments tool count |

**PreToolUse special handling:**
- For `AskUserQuestion` tool, captures the question text from `tool_input.questions` and stores it in `pending_question`

**PostToolUseFailure input fields:**
- `tool_name`, `tool_input`, `tool_use_id`
- `error` - Error message describing the failure
- `is_interrupt` - Whether the failure was due to user interrupt

**PostToolUseFailure behavior:**
- Clears `pending_tool_name` and `pending_question`
- Sets `work_status` to "waiting" and `attention_reason` to "awaitingReply"
- This handles permission denials - when a user rejects a tool, `PostToolUseFailure` fires and resets the session state

**Also detects:**
- Branch creation (`git checkout -b`, `git switch -c`) to auto-create workstreams

**Why it matters:** Tool tracking shows what Claude is actually doing - reading files, running commands, making edits. The tool count and last-tool info help you understand session activity at a glance.

### `codex-notify.js`
**Fires:** Codex CLI notify hook (agent-turn-complete)

**Input fields:**
- `session_id` (preferred), or `conversation_id`, `thread_id`, `session.id`, `conversation.id`

**Tracks:**
- Sets `work_status` to `waiting`
- Clears pending tool/question state
- Captures `terminal_session_id` and `terminal_app` from environment

**Why it matters:** Codex sessions are detected via FSEvents file watching (`CodexRolloutWatcher.swift`), which runs in the macOS app process and has no access to terminal environment variables. This notify hook runs *inside* the terminal process, so it can capture `ITERM_SESSION_ID` and `TERM_PROGRAM` - enabling the "Find Terminal" feature for Codex sessions.

## Input Schema

All hooks receive JSON on stdin from Claude Code:

```json
{
  "session_id": "abc-123-def",
  "cwd": "/path/to/project",
  "hook_event_name": "PreToolUse",
  "tool_name": "Bash",
  "tool_input": { "command": "npm test" },
  "transcript_path": "/path/to/transcript.jsonl"
}
```

Fields vary by event - see each hook's JSDoc for specifics.

## Database Updates

Hooks update the `sessions` table in `~/.orbitdock/orbitdock.db`:

| Field | Updated by |
|-------|------------|
| `status` | session-start, session-end |
| `work_status` | status-tracker, tool-tracker |
| `attention_reason` | status-tracker, tool-tracker |
| `prompt_count` | status-tracker (UserPromptSubmit) |
| `tool_count` | tool-tracker (PostToolUse, PostToolUseFailure) |
| `last_tool` | tool-tracker (PreToolUse) |
| `pending_tool_name` | status-tracker (permission_prompt), tool-tracker (cleared on PostToolUse/PostToolUseFailure) |
| `pending_tool_input` | status-tracker (permission_prompt) - JSON string of tool parameters for rich UI display |
| `pending_question` | tool-tracker (PreToolUse for AskUserQuestion), cleared on PostToolUseFailure |
| `summary` | status-tracker (Stop) - synced from Claude's sessions-index.json |
| `terminal_session_id` | session-start (Claude), codex-notify (Codex) - iTerm2 session UUID |
| `terminal_app` | session-start (Claude), codex-notify (Codex) - e.g., `iTerm.app` |

## App Notifications

After each database update, hooks call:

```bash
notifyutil -p com.orbitdock.session.updated
```

The OrbitDock macOS app listens for this Darwin notification and refreshes its UI immediately. This is why updates appear instantly without polling.

## Installation

Run the installer from the repository root:

```bash
node install.js
```

This:
- Configures all hooks in `~/.claude/settings.json`
- Sets `async: true` so hooks run in background without blocking Claude
- Sets up the MCP server in `~/.claude/mcp.json`

After installing, restart Claude Code to activate the hooks.

## Codex Notify Hook Setup

Codex CLI supports a notify hook that fires at the end of each agent turn. This hook is **required** for:
- Marking Codex sessions as "waiting" after each turn
- **Enabling "Find Terminal" for Codex sessions** (captures iTerm2 session ID)

Configure it in `~/.codex/config.toml`:

```toml
notify = ["node", "/path/to/claude-dashboard/hooks/codex-notify.js"]
```

Without this hook, Codex sessions will appear in OrbitDock (via FSEvents watcher) but you won't be able to focus their terminal windows.

## Debugging

**Check the hook log file:**

```bash
tail -f ~/.orbitdock/hooks.log
```

The log includes timestamps, log levels, and structured JSON data for each event.

**Check the database directly:**

```bash
sqlite3 ~/.orbitdock/orbitdock.db "SELECT id, work_status, prompt_count, tool_count, last_tool FROM sessions ORDER BY started_at DESC LIMIT 5;"
```

**Set debug mode for verbose output:**

```bash
ORBITDOCK_DEBUG=1 claude
```

## Testing

Run the test suite:

```bash
npm test
```

Tests cover all hooks with various event types and edge cases (missing fields, invalid JSON, etc.).
