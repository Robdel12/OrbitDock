# Conversation Contracts

Last updated: 2026-03-13

This doc describes the typed conversation row system that OrbitDock uses for all conversation data across HTTP and WebSocket.

Source of truth: `orbitdock-server/crates/protocol/src/conversation_contracts/` and `domain_events/`.

## Overview

Every piece of conversation content is a `ConversationRow` — a tagged enum with 12 variants. Rows are wrapped in `ConversationRowEntry` which adds session scoping and sequence ordering.

The server normalizes both Claude and Codex provider payloads into this shared contract. Clients never parse provider-specific JSON.

## ConversationRowEntry

```json
{
  "session_id": "od-abc123",
  "sequence": 42,
  "row": { "row_type": "...", ... }
}
```

- `session_id` — parent session
- `sequence` — monotonic ordering within the session
- `row` — tagged `ConversationRow` (discriminated by `row_type`)

## ConversationRowPage

Paginated response used by `GET /api/sessions/{id}/conversation` and `GET /api/sessions/{id}/messages`.

```json
{
  "rows": [ ... ],
  "total_row_count": 120,
  "has_more_before": true,
  "oldest_sequence": 71,
  "newest_sequence": 120
}
```

## ConversationRow Variants

### Message Rows

Simple text content rows. All share the same shape.

| `row_type` | Description |
|---|---|
| `user` | User prompt |
| `assistant` | AI response text |
| `thinking` | Extended thinking / reasoning trace |
| `system` | System messages, errors, compaction notices |

```json
{
  "row_type": "assistant",
  "id": "msg-123",
  "content": "Here's the implementation...",
  "turn_id": "turn-3",
  "timestamp": "2026-03-13T12:00:00Z"
}
```

### Tool Row

The primary row type for tool executions. Carries typed invocation and result payloads, semantic family/kind classification, status tracking, and render hints.

```json
{
  "row_type": "tool",
  "id": "toolu_abc123",
  "provider": "claude",
  "family": "shell",
  "kind": "bash",
  "status": "completed",
  "title": "Bash",
  "subtitle": "git status",
  "summary": "Ran git status in /tmp/repo",
  "duration_ms": 1200,
  "invocation": {
    "Shell": {
      "command": "git status",
      "cwd": "/tmp/repo"
    }
  },
  "result": {
    "Shell": {
      "command": "git status",
      "output": "On branch main\nnothing to commit",
      "exit_code": 0
    }
  },
  "render_hints": {
    "can_expand": true,
    "default_expanded": false,
    "monospace_summary": true
  }
}
```

### Activity Group Row

Groups contiguous tool rows within a turn for collapsed display.

```json
{
  "row_type": "activity_group",
  "id": "group-abc",
  "group_kind": "tool_block",
  "title": "3 file operations",
  "child_count": 3,
  "children": [ ... ],
  "status": "completed",
  "render_hints": { "can_expand": true }
}
```

`group_kind` values: `tool_block`, `worker_block`, `mixed_block`.

### Question Row

User-facing questions from the AI agent.

```json
{
  "row_type": "question",
  "id": "q-123",
  "title": "Which approach?",
  "prompts": [
    {
      "id": "prompt-1",
      "question": "Which database should we use?",
      "options": [
        { "label": "PostgreSQL", "description": "Full-featured relational" },
        { "label": "SQLite", "description": "Embedded, zero-config" }
      ],
      "allows_multiple": false,
      "allows_other": true,
      "secret": false
    }
  ],
  "response": null,
  "render_hints": {}
}
```

### Approval Row

Tool execution approval requests.

```json
{
  "row_type": "approval",
  "id": "req-abc",
  "title": "Bash: rm -rf /tmp/build",
  "request": {
    "id": "req-abc",
    "kind": "command",
    "family": "shell",
    "status": "needs_input",
    "command": "rm -rf /tmp/build",
    "preview": { ... }
  },
  "render_hints": { "emphasized": true }
}
```

### Worker Row

Subagent/worker lifecycle events.

```json
{
  "row_type": "worker",
  "id": "agent-xyz",
  "title": "Explore agent",
  "worker": {
    "id": "agent-xyz",
    "agent_type": "Explore",
    "status": "running",
    "task_summary": "Search for API endpoints"
  },
  "operation": "spawn",
  "render_hints": {}
}
```

### Plan Row

Plan mode content and step tracking.

```json
{
  "row_type": "plan",
  "id": "plan-1",
  "title": "Implementation Plan",
  "payload": {
    "mode": "plan",
    "summary": "3-phase migration",
    "steps": [
      { "title": "Update protocol types", "status": "completed" },
      { "title": "Update connectors", "status": "in_progress" },
      { "title": "Update transport", "status": "pending" }
    ]
  },
  "render_hints": { "default_expanded": true }
}
```

### Hook Row

Hook execution notifications.

```json
{
  "row_type": "hook",
  "id": "hook-1",
  "title": "PreToolUse hook",
  "payload": {
    "hook_name": "lint-check",
    "event_name": "PreToolUse",
    "phase": "pre",
    "status": "completed",
    "duration_ms": 450
  },
  "render_hints": {}
}
```

### Handoff Row

Agent-to-agent handoff events.

```json
{
  "row_type": "handoff",
  "id": "handoff-1",
  "title": "Handoff to review agent",
  "payload": {
    "target": "review-agent",
    "summary": "Code review needed for PR #42"
  },
  "render_hints": {}
}
```

## Tool Family

Semantic grouping for tool rows. Determines icon, color, and grouping behavior in the UI.

| Family | Tools |
|---|---|
| `shell` | Bash, command execution |
| `file_read` | Read, view file |
| `file_change` | Edit, Write, NotebookEdit |
| `search` | Glob, Grep, ToolSearch |
| `web` | WebSearch, WebFetch |
| `image` | ViewImage, ImageGeneration |
| `agent` | SpawnAgent, SendAgentInput, ResumeAgent, WaitAgent, CloseAgent |
| `question` | AskUserQuestion |
| `approval` | Tool approval requests |
| `permission_request` | Permission elevation |
| `plan` | EnterPlanMode, ExitPlanMode, UpdatePlan |
| `todo` | TodoWrite, task management |
| `config` | Config changes |
| `mcp` | McpToolCall, ReadMcpResource, ListMcpResources |
| `hook` | HookNotification |
| `handoff` | HandoffRequested |
| `context` | CompactContext |
| `generic` | Unknown or unclassified tools |

## Tool Kind

Fine-grained tool type. Every `ToolRow` has exactly one kind.

`bash`, `read`, `edit`, `write`, `notebook_edit`, `glob`, `grep`, `tool_search`, `web_search`, `web_fetch`, `mcp_tool_call`, `read_mcp_resource`, `list_mcp_resources`, `subscribe_mcp_resource`, `unsubscribe_mcp_resource`, `subscribe_polling`, `unsubscribe_polling`, `dynamic_tool_call`, `spawn_agent`, `send_agent_input`, `resume_agent`, `wait_agent`, `close_agent`, `task_output`, `task_stop`, `ask_user_question`, `enter_plan_mode`, `exit_plan_mode`, `update_plan`, `todo_write`, `config`, `enter_worktree`, `hook_notification`, `handoff_requested`, `compact_context`, `view_image`, `image_generation`, `generic`

## Tool Status

| Status | Meaning |
|---|---|
| `pending` | Queued, not started |
| `running` | Actively executing |
| `completed` | Finished successfully |
| `failed` | Finished with error |
| `cancelled` | Cancelled by user or system |
| `blocked` | Waiting on external condition |
| `needs_input` | Waiting for user input (approval/question) |

## Tool Invocation Payloads

Typed input payloads carried on `ToolRow.invocation`. The variant matches the tool family.

### Shell

```json
{ "Shell": { "command": "git status", "cwd": "/tmp/repo", "input": null, "output": null, "exit_code": null } }
```

### FileRead

```json
{ "FileRead": { "path": "src/main.rs", "language": "rust", "content": null } }
```

### FileChange

```json
{ "FileChange": { "path": "src/main.rs", "diff": "--- a/...\n+++ b/...", "summary": "Updated imports", "additions": 3, "deletions": 1 } }
```

### Search

```json
{ "Search": { "query": "fn main", "scope": "src/" } }
```

### WebSearch

```json
{ "WebSearch": { "query": "rust async patterns", "results": [] } }
```

### WebFetch

```json
{ "WebFetch": { "url": "https://...", "title": "Page Title", "content": null } }
```

### McpTool

```json
{ "McpTool": { "server": "github", "tool_name": "list_issues", "input": { "repo": "org/repo" }, "output": null } }
```

### Worker

```json
{ "Worker": { "worker_id": "agent-1", "label": "Explore", "agent_type": "Explore", "task_summary": "Search codebase", "input": null } }
```

### Generic

Catch-all for unclassified tools.

```json
{ "Generic": { "tool_name": "CustomTool", "raw_input": { ... } } }
```

Other payload types: `Question`, `PlanMode`, `Todo`, `ContextCompaction`, `Handoff`, `ImageView`, `ImageGeneration`, `Config`, `Hook`.

## Tool Result Payloads

Carried on `ToolRow.result` when the tool completes. Mirrors invocation structure with output data.

### Shell (result)

```json
{ "Shell": { "command": "git status", "output": "On branch main\n...", "exit_code": 0 } }
```

### Search (result)

```json
{ "Search": { "query": "fn main", "matches": ["src/main.rs:1"], "total_matches": 1 } }
```

### Generic (result)

```json
{ "Generic": { "tool_name": "CustomTool", "raw_output": { ... }, "summary": "Completed successfully" } }
```

### Worker (result)

```json
{ "Worker": { "worker_id": "agent-1", "summary": "Found 3 API endpoints", "output": "..." } }
```

## Render Hints

Optional display guidance from server to client. All fields default to `false`/`null`.

```json
{
  "can_expand": true,
  "default_expanded": false,
  "emphasized": false,
  "monospace_summary": true,
  "accent_tone": "warning"
}
```

## WebSocket Events

### `conversation_bootstrap`

Sent on session subscribe. Contains the full `SessionState` plus a `ConversationRowPage`.

```json
{
  "type": "conversation_bootstrap",
  "session": { ... },
  "conversation": {
    "rows": [ ... ],
    "total_row_count": 120,
    "has_more_before": true,
    "oldest_sequence": 71,
    "newest_sequence": 120
  }
}
```

### `conversation_rows_changed`

Incremental row updates. Contains upserted rows and removed row IDs.

```json
{
  "type": "conversation_rows_changed",
  "session_id": "od-...",
  "upserted": [
    {
      "session_id": "od-...",
      "sequence": 43,
      "row": { "row_type": "tool", ... }
    }
  ],
  "removed_row_ids": [],
  "total_row_count": 43
}
```

Clients should upsert rows by ID (matching `sequence` for ordering) and remove any IDs in `removed_row_ids`.

## Provider Mapping

Both Claude and Codex events normalize into the same row types:

| Claude SDK | Codex Thread Item | ConversationRow |
|---|---|---|
| assistant text | agentMessage | `assistant` |
| user message | userMessage | `user` |
| thinking block | reasoning | `thinking` |
| Bash tool_use | commandExecution | `tool` (shell/bash) |
| Read/Edit/Write | fileChange | `tool` (file_read/file_change) |
| Glob/Grep | - | `tool` (search) |
| WebSearch/WebFetch | webSearch | `tool` (web) |
| Agent tool_use | collabAgentToolCall | `tool` (agent) or `worker` |
| AskUserQuestion | question | `question` |
| MCP tool_use | mcpToolCall | `tool` (mcp) |
| plan mode | plan/review mode | `plan` |
| hook events | hook events | `hook` |
| - | handoff | `handoff` |
| compact boundary | contextCompaction | `system` + `tool` (context) |
