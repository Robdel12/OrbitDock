# OrbitDock Client Specification

Status: Draft v1

Purpose: Define everything a developer or LLM needs to build a client application for the OrbitDock server — a mission control for AI coding agents.

## 1. What OrbitDock Is

OrbitDock is a server that manages AI coding agent sessions. It supports two providers — **Claude** (Anthropic's Claude Code CLI) and **Codex** (OpenAI's Codex agent) — through a unified protocol. A client connects over HTTP REST and WebSocket to:

- Create, observe, and control coding agent sessions
- Approve or deny tool executions and answer agent questions
- Browse conversation history with typed, structured rows
- Manage git worktrees for parallel development
- Run Mission Control — automated issue-to-agent orchestration via Linear

The server owns all state. Clients are thin views that render server-pushed events and fire REST mutations. Clients never parse provider-specific JSON — the server normalizes everything into a shared contract.

## 2. Core Concepts

### 2.1 Sessions

A session is a long-running coding agent conversation. Sessions have:

- **provider** — `"claude"` or `"codex"`
- **status** — `"active"`, `"idle"`, `"ended"`, `"error"`
- **work_status** — `"working"`, `"waiting"`, `"tool_pending"`, `"idle"`
- **project_path** — the filesystem working directory
- **revision** — monotonic counter incremented on every state change

Sessions are created via REST (`POST /api/sessions`), observed via WebSocket subscription, and controlled through REST actions (send message, approve, interrupt, etc.).

### 2.2 Conversation Rows

All conversation content is a `ConversationRow` — a tagged union with 12 variants, wrapped in a `ConversationRowEntry`:

```json
{
  "session_id": "od-abc123",
  "sequence": 42,
  "turn_id": "turn-3",
  "row": { "row_type": "assistant", "id": "msg-2", "content": "...", ... }
}
```

- **sequence** — monotonic ordering within the session. Used for pagination and ordering.
- **turn_id** — groups rows that belong to the same conversational turn.
- **row_type** — discriminator for the row variant (see Section 4).

### 2.3 Approvals

When an agent wants to run a potentially dangerous tool, the server pauses execution and surfaces an approval request. The client must present this to the user and send back a decision (`approved` or `denied`).

Approval requests appear as:
- `approval_requested` WebSocket events
- `approval` row type in the conversation

### 2.4 Worktrees

Git worktrees let agents work on isolated branches without disturbing the main checkout. The server tracks worktree lifecycle and supports forking sessions into worktrees.

### 2.5 Missions (Mission Control)

A mission connects a Linear project to automated agent sessions. The server polls Linear for issues, dispatches them to agents in isolated worktrees, and tracks progress. Missions are configured via `MISSION.md` files in the repo.

## 3. Transport

### 3.1 HTTP REST

Used for reads, mutations, and fire-and-forget actions. Base URL is configurable (default `http://localhost:19285`).

When auth is configured:

```http
Authorization: Bearer <token>
```

All routes except `GET /health` require auth when enabled.

**Response conventions:**

- Fire-and-forget mutations return `{"accepted": true}` with `202 Accepted`
- Errors return `{"code": "string_code", "error": "human message"}` with appropriate HTTP status

### 3.2 WebSocket

Connect to `/ws` for real-time events. WebSocket is used for:

- Session subscriptions (live conversation updates)
- Server-pushed state changes
- Approval prompts
- Shell streaming output

**Client messages** (JSON, sent by the client):

```json
{"type": "subscribe_list"}
{"type": "subscribe_session", "session_id": "od-...", "since_revision": 120, "include_snapshot": true}
{"type": "unsubscribe_session", "session_id": "od-..."}
```

**Server events** (JSON, pushed by the server):

- `conversation_bootstrap` — full session + conversation page on subscribe
- `conversation_rows_changed` — incremental row upserts/removals
- `session_delta` — session metadata changes (status, tokens, name)
- `approval_requested` — tool needs user approval
- `approval_decision_result` — approval outcome
- `tokens_updated` — token usage snapshot
- `session_created` / `session_ended` / `session_forked`
- `shell_started` / `shell_output` — shell execution streaming
- `rate_limit_event` / `prompt_suggestion`
- `skills_list` / `mcp_tools_list`
- `review_comment_created` / `review_comment_updated` / `review_comment_deleted`
- `worktree_created` / `worktree_removed` / `worktree_status_changed`
- `mission_updated` / `mission_issue_updated` / `mission_orchestrator_status`

### 3.3 Transport Rules

- Use REST for reads and mutations. Use WebSocket for subscriptions and real-time interaction.
- REST mutations often produce WebSocket broadcasts so other connected clients stay in sync.
- When in doubt, use REST. Only use WebSocket when the operation needs a persistent connection.

## 4. Conversation Row Types

Every row has `row_type` as the discriminator. Here are all 12 variants:

### Message Rows

| row_type | Description |
|---|---|
| `user` | User prompt |
| `assistant` | AI response text |
| `thinking` | Extended thinking / reasoning trace |
| `system` | System messages, errors, compaction notices |

All message rows share the same shape:

```json
{
  "row_type": "assistant",
  "id": "msg-123",
  "content": "Here's the implementation...",
  "turn_id": "turn-3",
  "timestamp": "2026-03-13T12:00:00Z",
  "is_streaming": true,
  "images": []
}
```

- `is_streaming` — `true` while the assistant is still generating. Content updates arrive via `conversation_rows_changed`.
- `images` — optional array of image attachments on user messages.

### Tool Row

The workhorse row type. Represents any tool execution.

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
  "turn_id": "turn-3",
  "invocation": { "Shell": { "command": "git status", "cwd": "/tmp/repo" } },
  "result": { "Shell": { "command": "git status", "output": "On branch main\n...", "exit_code": 0 } },
  "render_hints": { "can_expand": true, "default_expanded": false, "monospace_summary": true }
}
```

**Tool families** determine icon, color, and grouping:

| Family | Description |
|---|---|
| `shell` | Command execution (Bash) |
| `file_read` | Read, view file |
| `file_change` | Edit, Write, NotebookEdit |
| `search` | Glob, Grep, ToolSearch |
| `web` | WebSearch, WebFetch |
| `image` | ViewImage, ImageGeneration |
| `agent` | Subagent spawn/resume/close |
| `question` | AskUserQuestion |
| `approval` | Tool approval requests |
| `permission_request` | Permission elevation |
| `plan` | Plan mode operations |
| `todo` | Task management |
| `mcp` | MCP tool calls |
| `hook` | Hook notifications |
| `context` | Context compaction |
| `generic` | Unclassified tools |

**Tool statuses**: `pending`, `running`, `completed`, `failed`, `cancelled`, `blocked`, `needs_input`

### Activity Group Row

Groups contiguous tool rows for collapsed display.

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

### Question Row

Agent is asking the user a question.

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

Tool execution needs user approval.

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

Subagent lifecycle events.

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

### Hook Row, Handoff Row

Less common row types for hook execution notifications and agent-to-agent handoffs. See `docs/conversation-contracts.md` for full payloads.

### Render Hints

Optional display guidance on every row. All fields default to `false`/`null`.

```json
{
  "can_expand": true,
  "default_expanded": false,
  "emphasized": false,
  "monospace_summary": true,
  "accent_tone": "warning"
}
```

Clients should honor render hints when displaying rows.

## 5. Key Client Workflows

### 5.1 Session List

1. `GET /api/sessions` to load initial list.
2. Send `{"type": "subscribe_list"}` over WebSocket.
3. React to `session_created`, `session_ended`, `session_delta` events to keep the list current.

Each session summary includes:

```json
{
  "id": "od-...",
  "provider": "codex",
  "project_path": "/Users/.../repo",
  "status": "active",
  "work_status": "waiting",
  "active_worker_count": 1,
  "pending_tool_family": "shell",
  "forked_from_session_id": null
}
```

### 5.2 Session Conversation View

1. `GET /api/sessions/{id}/conversation?limit=50` for the initial bootstrap (session state + newest rows).
2. Send `{"type": "subscribe_session", "session_id": "od-...", "include_snapshot": false}` (skip snapshot since you already have it from REST).
3. Handle `conversation_rows_changed` events — upsert rows by ID, remove rows in `removed_row_ids`, order by `sequence`.
4. For infinite scroll backward: `GET /api/sessions/{id}/messages?before_sequence=71&limit=50`.
5. Handle `session_delta` events for status, token, and name changes.

**Streaming**: When `is_streaming` is `true` on an assistant row, expect content updates via `conversation_rows_changed` with the same row ID but updated content.

### 5.3 Sending a Message

```
POST /api/sessions/{session_id}/messages
{
  "content": "Fix the login bug",
  "images": [],
  "mentions": [],
  "skills": []
}
```

Returns `202 Accepted` with the dispatched user row. The agent's response streams in via WebSocket.

### 5.4 Approving a Tool

When `approval_requested` arrives via WebSocket (or an `approval` row appears in the conversation):

1. Display the tool request to the user with the preview/command information.
2. Collect the user's decision.
3. Send the decision:

```
POST /api/sessions/{session_id}/approve
{
  "request_id": "req-...",
  "decision": "approved"
}
```

Supported decisions: `"approved"`, `"denied"`.

Optional fields: `message` (feedback), `interrupt` (stop after this tool), `updated_input` (modify tool input before execution).

### 5.5 Answering a Question

When a `question` row appears:

1. Display the question with its options.
2. Collect the user's selection.
3. Send the answer:

```
POST /api/sessions/{session_id}/answer
{
  "request_id": "req-...",
  "answer": "Use PostgreSQL",
  "question_id": "prompt-1",
  "answers": { "prompt-1": ["PostgreSQL"] }
}
```

### 5.6 Creating a Session

```
POST /api/sessions
{
  "provider": "claude",
  "cwd": "/Users/.../repo"
}
```

Optional fields: `model`, `effort`, `approval_policy`, `sandbox_mode`, `permission_mode`, `allowed_tools`, `disallowed_tools`, `collaboration_mode`, `multi_agent`, `personality`, `service_tier`, `developer_instructions`, `system_prompt`, `append_system_prompt`.

### 5.7 Session Lifecycle Operations

| Action | Endpoint | Notes |
|---|---|---|
| End session | `POST /api/sessions/{id}/end` | |
| Resume persisted session | `POST /api/sessions/{id}/resume` | |
| Take over passive session | `POST /api/sessions/{id}/takeover` | |
| Fork session | `POST /api/sessions/{id}/fork` | Creates a new session from conversation history |
| Fork into worktree | `POST /api/sessions/{id}/fork-to-worktree` | Creates worktree + fork |
| Interrupt active turn | `POST /api/sessions/{id}/interrupt` | |
| Undo last turn | `POST /api/sessions/{id}/undo` | |
| Rollback N turns | `POST /api/sessions/{id}/rollback` | Body: `{"num_turns": 2}` |
| Compact context | `POST /api/sessions/{id}/compact` | |
| Rename | `PATCH /api/sessions/{id}/name` | Body: `{"name": "..."}` |
| Update config | `PATCH /api/sessions/{id}/config` | Partial update of session settings |

### 5.8 Worktree Management

1. List worktrees: `GET /api/worktrees?repo_root=/path/to/repo`
2. Create: `POST /api/worktrees` with `repo_path`, `branch_name`, optional `base_branch`
3. Delete: `DELETE /api/worktrees/{id}?force=false&delete_branch=false`
4. Discover existing: `POST /api/worktrees/discover` with `repo_path`

Worktree events arrive via WebSocket: `worktree_created`, `worktree_removed`, `worktree_status_changed`.

### 5.9 Mission Control

#### Listing and Creating Missions

```
GET /api/missions              — list all missions
POST /api/missions             — create: {"name": "...", "repo_root": "..."}
GET /api/missions/{id}         — full detail with issues, settings, file status
PUT /api/missions/{id}         — update name/enabled/paused
DELETE /api/missions/{id}      — delete
```

#### Mission Issues

```
GET /api/missions/{id}/issues              — list issues
POST /api/missions/{id}/issues/{iid}/retry — retry a failed issue
```

Issue states: `queued`, `claimed`, `running`, `retry_queued`, `completed`, `failed`.

#### Mission Settings

```
PUT /api/missions/{id}/settings   — partial merge with MISSION.md config
GET /api/missions/{id}/default-template — get default prompt template
POST /api/missions/{id}/scaffold  — write default MISSION.md to repo
POST /api/missions/{id}/migrate-workflow — convert WORKFLOW.md to MISSION.md
```

Settings cover: provider strategy, per-provider agent config (Claude and Codex), trigger/polling, orchestration limits, and prompt template.

#### Orchestration

```
POST /api/missions/{id}/start-orchestrator — start the polling loop
POST /api/missions/{id}/dispatch           — manually dispatch a specific issue
```

##### MISSION.md Orchestration Config

```yaml
orchestration:
  max_retries: 3
  stall_timeout: 600
  base_branch: main
  state_on_dispatch: "In Progress"   # tracker state when issue is dispatched
  state_on_complete: "In Review"     # tracker state when session completes
```

The state lifecycle flows through the trigger filters:

1. `trigger.filters.states` defines which states to poll for candidates (e.g. `[Todo, Next]`)
2. `state_on_dispatch` — issue moves to this state when claimed by a session (default: "In Progress")
3. `state_on_complete` — issue moves to this state when a session finishes (default: "In Review")

Tracker writes (state transitions and comments) are best-effort — failures are logged but never block the dispatch or reconciliation pipeline.

##### Mission Tools

Every dispatched session receives 8 mission-specific tools that let the agent interact with the issue tracker during execution:

| Tool | Description |
|---|---|
| `mission_get_issue` | Fetch current issue details (title, description, status, labels, URL) |
| `mission_post_update` | Post a comment on the current issue |
| `mission_update_comment` | Edit an existing comment by ID |
| `mission_get_comments` | List comments on the current issue |
| `mission_set_status` | Move the issue to a workflow state (e.g. "In Review") |
| `mission_link_pr` | Attach a pull request URL to the issue |
| `mission_create_followup` | Create a backlog issue for out-of-scope work |
| `mission_report_blocked` | Signal that the agent is blocked and needs human intervention |

Tool injection differs by provider:

- **Claude**: A `.mcp.json` file is written to the worktree root at dispatch time. It configures an `orbitdock-mission` MCP server (`orbitdock mcp-mission-tools` subcommand) that Claude auto-discovers at startup. Environment variables (`LINEAR_API_KEY`, `ORBITDOCK_ISSUE_ID`, `ORBITDOCK_ISSUE_IDENTIFIER`, `ORBITDOCK_MISSION_ID`) are injected into the MCP server config.
- **Codex**: Tools are registered as `DynamicToolSpec` entries passed via `start_thread_with_tools`. The server handles tool execution directly.

Tool definitions live in `domain/mission_control/tools.rs`. The shared executor in `domain/mission_control/executor.rs` handles all tool calls against the Linear API for both paths. `mission_report_blocked` sets the issue's orchestration state to `blocked` and posts a comment — the orchestrator will not retry blocked issues.

#### Server-Level Mission Config

```
GET/POST/DELETE /api/server/linear-key    — Linear API key management
GET /api/server/tracker-keys              — status of all tracker keys
GET/PUT /api/server/mission-defaults      — default provider strategy
```

### 5.10 Shell Execution

Clients can execute shell commands in a session's context:

```
POST /api/sessions/{id}/shell/exec
{ "command": "git status", "cwd": "/path", "timeout_secs": 120 }
```

Output streams via WebSocket `shell_started` and `shell_output` events. Cancel with `POST /api/sessions/{id}/shell/cancel`.

### 5.11 Image Attachments

Upload: `POST /api/sessions/{id}/attachments/images` with raw image bytes and `Content-Type` header. Returns an `ImageInput` reference to include in messages.

Download: `GET /api/sessions/{id}/attachments/images/{attachment_id}` returns raw bytes.

### 5.12 Review Comments

Inline code review comments tied to specific files and lines:

```
POST /api/sessions/{id}/review-comments
{ "file_path": "src/main.rs", "line_start": 42, "body": "This needs error handling" }
```

Update: `PATCH /api/review-comments/{comment_id}`
Delete: `DELETE /api/review-comments/{comment_id}`
List: `GET /api/sessions/{id}/review-comments?turn_id=turn-3`

## 6. Client State Management

### 6.1 Session State

The server is the source of truth. Clients should:

- Store sessions in a map keyed by session ID.
- Apply `session_delta` events as partial patches.
- Use `revision` to detect stale state.

### 6.2 Conversation State

Conversation rows are an ordered list keyed by `sequence`:

- **Upsert** rows from `conversation_rows_changed.upserted` — match by row ID, insert or replace.
- **Remove** rows from `conversation_rows_changed.removed_row_ids`.
- **Order** by `sequence` ascending for display.
- **Group** by `turn_id` for visual turn boundaries.

Pagination uses `before_sequence` — fetch older rows by passing the smallest sequence you have.

### 6.3 Approval State

Approvals are time-sensitive. When `approval_requested` arrives:

1. Surface it immediately in the UI (badge, notification, inline prompt).
2. Track the `request_id` and `approval_version`.
3. After sending a decision, wait for `approval_decision_result` to confirm the outcome.
4. The `active_request_id` field tells you if another approval is immediately pending.

### 6.4 WebSocket Reconnection

Clients should reconnect on disconnect and re-subscribe to active sessions. Use `since_revision` to get only events missed during the disconnect:

```json
{
  "type": "subscribe_session",
  "session_id": "od-...",
  "since_revision": 120,
  "include_snapshot": false
}
```

If the server cannot replay from the requested revision, it sends a full snapshot instead.

## 7. Server Info and Auth

### 7.1 Health Check

`GET /health` — always returns `{"status": "ok"}`. No auth required.

### 7.2 Provider Setup

**OpenAI/Codex:**
- `GET /api/server/openai-key` — check if configured
- `POST /api/server/openai-key` — set key
- `GET /api/codex/account` — check auth status
- `POST /api/codex/login/start` — start browser login flow

**Claude:** Claude auth is managed through the Claude Code CLI, not the OrbitDock server.

**Linear (for Mission Control):**
- `GET /api/server/linear-key` — check if configured
- `POST /api/server/linear-key` — set key
- `DELETE /api/server/linear-key` — remove key

### 7.3 Models

- `GET /api/models/codex` — available Codex models
- `GET /api/models/claude` — available Claude models

### 7.4 Usage

- `GET /api/usage/codex` — current Codex token usage
- `GET /api/usage/claude` — current Claude token usage

## 8. Capabilities

### 8.1 Skills

Skills are reusable prompt extensions available to sessions.

- `GET /api/sessions/{id}/skills` — list skills (query: `cwd[]`, `force_reload`)

### 8.2 Plugins

Plugins replace the old remote-skill browse/download flow for Codex-backed sessions.

- `GET /api/sessions/{id}/plugins` — list plugin marketplaces (query: `cwd[]`, `force_remote_sync`)
- `POST /api/sessions/{id}/plugins/install` — install a plugin (`marketplacePath`, `pluginName`, `forceRemoteSync`)
- `POST /api/sessions/{id}/plugins/uninstall` — uninstall a plugin (`pluginId`, `forceRemoteSync`)

### 8.3 MCP (Model Context Protocol)

MCP provides external tool integrations (GitHub, Linear, etc.).

- `GET /api/sessions/{id}/mcp/tools` — current tool catalog
- `POST /api/sessions/{id}/mcp/refresh` — refresh servers
- `POST /api/sessions/{id}/mcp/toggle` — enable/disable a server
- `POST /api/sessions/{id}/mcp/authenticate` — start auth for a server
- `POST /api/sessions/{id}/mcp/clear-auth` — clear saved auth
- `POST /api/sessions/{id}/mcp/servers` — apply server config

### 8.3 Permissions

- `GET /api/sessions/{id}/permissions` — effective permission rules
- `POST /api/sessions/{id}/permissions/rules` — add a permission rule
- `DELETE /api/sessions/{id}/permissions/rules` — remove a permission rule
- `POST /api/sessions/{id}/permissions/respond` — respond to a permission grant request

### 8.4 Session Instructions

- `GET /api/sessions/{id}/instructions` — view CLAUDE.md, system prompt, developer instructions

## 9. Implementation Notes

### 9.1 Provider Normalization

Both Claude and Codex events normalize into the same row types. Clients should never branch on provider for rendering — use `row_type`, `family`, and `kind` instead.

| Claude SDK | Codex Thread Item | ConversationRow |
|---|---|---|
| assistant text | agentMessage | `assistant` |
| user message | userMessage | `user` |
| thinking block | reasoning | `thinking` |
| Bash tool_use | commandExecution | `tool` (shell/bash) |
| Read/Edit/Write | fileChange | `tool` (file_read/file_change) |
| Glob/Grep | — | `tool` (search) |
| WebSearch/WebFetch | webSearch | `tool` (web) |
| Agent tool_use | collabAgentToolCall | `tool` (agent) or `worker` |
| AskUserQuestion | question | `question` |
| MCP tool_use | mcpToolCall | `tool` (mcp) |
| plan mode | plan/review mode | `plan` |
| hook events | hook events | `hook` |
| — | handoff | `handoff` |
| compact boundary | contextCompaction | `system` + `tool` (context) |

### 9.2 Pagination

All paginated endpoints follow the same pattern:

```json
{
  "rows": [...],
  "total_row_count": 120,
  "has_more_before": true,
  "oldest_sequence": 71,
  "newest_sequence": 120
}
```

- `has_more_before` — whether older rows exist
- Use `before_sequence` with the `oldest_sequence` value to fetch the next page

### 9.3 Error Handling

HTTP errors return:

```json
{
  "code": "session_not_found",
  "error": "Session od-abc123 not found"
}
```

Common error codes: `not_found`, `session_not_found`, `already_active`, `invalid_request`, `db_error`, `runtime_error`.

### 9.4 Filesystem Browsing

For project/directory selection UIs:

- `GET /api/fs/browse?path=/Users/...` — list directory entries
- `GET /api/fs/recent-projects` — recently active project roots
- `POST /api/git/init` — initialize a git repo

## 10. Full API Reference

See `docs/API.md` for the complete route-level contract with exact request/response JSON shapes for every endpoint.

See `docs/conversation-contracts.md` for the full typed conversation row schema including all invocation and result payload variants.

See `docs/server-architecture.md` for the internal architecture and code organization.
