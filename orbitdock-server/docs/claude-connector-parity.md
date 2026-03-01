# Claude Connector Feature Parity

Central checklist for what OrbitDock handles for Claude sessions — both **direct** (managed subprocess via stdin/stdout NDJSON) and **passive** (hook-based via HTTP POST).

**Source of truth:** `docs/node_modules/@anthropic-ai/claude-agent-sdk/` (v0.2.62, Claude Code v2.1.62)

Last updated: 2026-03-01

---

## SDK Stdout Message Types (CLI → OrbitDock)

The `StdoutMessage` union from the Claude Agent SDK defines all messages the CLI can emit on stdout. This includes the `SDKMessage` union members plus control protocol messages and internal types. The `type` field routes them in `dispatch_stdout_message()` (direct) or they arrive indirectly via hooks (passive).

### SDKMessage Union Members

| SDK Type | `type` field | `subtype` | Direct | Passive | Notes |
|---|---|---|---|---|---|
| `SDKSystemMessage` | `system` | `init` | ✅ | — | Captures session_id, model, tools, skills, slash_commands, mcp_servers, plugins, permissionMode, apiKeySource |
| `SDKCompactBoundaryMessage` | `system` | `compact_boundary` | ✅ | ✅ (PreCompact hook) | Direct: emits `ContextCompacted`. Passive: increments compact_count. Fields: `compact_metadata.trigger` ("manual"/"auto"), `compact_metadata.pre_tokens` |
| `SDKHookStartedMessage` | `system` | `hook_started` | ✅ | — | Registers managed thread to prevent duplicate passive sessions. Fields: `hook_id`, `hook_name`, `hook_event` |
| `SDKHookProgressMessage` | `system` | `hook_progress` | ✅ | — | Structured debug logging with hook_name, hook_event fields. Fields: `hook_id`, `hook_name`, `hook_event`, `stdout`, `stderr`, `output` |
| `SDKHookResponseMessage` | `system` | `hook_response` | ✅ | — | Structured info logging with hook_name, hook_event, outcome fields. Fields: `hook_id`, `hook_name`, `hook_event`, `output`, `stdout`, `stderr`, `exit_code?`, `outcome` ("success"/"error"/"cancelled") |
| `SDKStatusMessage` | `system` | `status` | ✅ | — | Handles `permissionMode` changes and `compacting` state. Fields: `status` ("compacting"/null), `permissionMode?` |
| `SDKTaskStartedMessage` | `system` | `task_started` | ✅ | — | Creates tool card with task_id as message ID. Fields: `task_id`, `tool_use_id?`, `description`, `task_type?` |
| `SDKTaskProgressMessage` | `system` | `task_progress` | ✅ | — | Updates tool card with usage stats. Fields: `task_id`, `tool_use_id?`, `description`, `usage.total_tokens`, `usage.tool_uses`, `usage.duration_ms`, `last_tool_name?` |
| `SDKTaskNotificationMessage` | `system` | `task_notification` | ✅ | — | Finalizes tool card. Fields: `task_id`, `tool_use_id?`, `status` ("completed"/"failed"/"stopped"), `output_file`, `summary`, `usage?` |
| `SDKFilesPersistedEvent` | `system` | `files_persisted` | ✅ | — | Emits `ConnectorEvent::FilesPersisted` → broadcasts `ServerMessage::FilesPersisted` to clients. Fields: `files[].filename`, `files[].file_id`, `failed[].filename`, `failed[].error`, `processed_at` |
| `SDKAssistantMessage` | `assistant` | — | ✅ | ✅ (transcript sync) | Extracts text + tool_use content blocks. Fields: `message` (BetaMessage), `parent_tool_use_id`, `error?` (auth/billing/rate_limit/etc), `uuid` |
| `SDKUserMessage` | `user` | — | ✅ | ✅ (transcript sync) | Creates user messages. Fields: `message` (MessageParam), `parent_tool_use_id`, `isSynthetic?`, `tool_use_result?`, `uuid?` |
| `SDKUserMessageReplay` | `user` | — (has `isReplay: true`) | ✅ (filtered) | — | Filtered out via `isReplay` flag (except `system` type). Same fields as SDKUserMessage + `isReplay: true` literal |
| `SDKPartialAssistantMessage` | `stream_event` | — | ✅ | — | Real-time streaming content deltas. Fields: `event` (BetaRawMessageStreamEvent), `parent_tool_use_id`, `uuid` |
| `SDKResultSuccess` | `result` | `success` | ✅ | ✅ (Stop hook) | Turn completed + token usage. Fields: `duration_ms`, `duration_api_ms`, `is_error`, `num_turns`, `result`, `stop_reason`, `total_cost_usd`, `usage`, `modelUsage`, `permission_denials`, `structured_output?` |
| `SDKResultError` | `result` | `error_during_execution` / `error_max_turns` / `error_max_budget_usd` / `error_max_structured_output_retries` | ✅ | ✅ (Stop hook) | Turn aborted. Same as SDKResultSuccess minus `result` + adds `errors[]`. Handled via `starts_with("error")` |
| `SDKToolProgressMessage` | `tool_progress` | — | ✅ | — | Updates tool card with elapsed time. Fields: `tool_use_id`, `tool_name`, `parent_tool_use_id`, `elapsed_time_seconds`, `task_id?` |
| `SDKToolUseSummaryMessage` | `tool_use_summary` | — | ✅ | — | Creates assistant message with human-readable tool summary. Fields: `summary`, `preceding_tool_use_ids[]` |
| `SDKAuthStatusMessage` | `auth_status` | — | ✅ (no-op) | — | Acknowledged, no action needed. Fields: `isAuthenticating`, `output[]`, `error?` |
| `SDKRateLimitEvent` | `rate_limit_event` | — | ✅ | — | Emits `ConnectorEvent::RateLimitEvent` → broadcasts `ServerMessage::RateLimitEvent` → Swift `RateLimitBanner` UI. Fields: `rate_limit_info.status` ("allowed"/"allowed_warning"/"rejected"), `rate_limit_info.resetsAt?`, `rate_limit_info.rateLimitType?`, `rate_limit_info.utilization?`, `rate_limit_info.overageStatus?`, `rate_limit_info.isUsingOverage?`, `rate_limit_info.surpassedThreshold?` |
| `SDKPromptSuggestionMessage` | `prompt_suggestion` | — | ✅ | — | Emits `ConnectorEvent::PromptSuggestion` → broadcasts `ServerMessage::PromptSuggestion` → Swift suggestion chips in composer. Enabled via `promptSuggestions: true` in initialize. Fields: `suggestion` |

### Control Protocol Messages (in StdoutMessage but not SDKMessage)

| Type | `type` field | Direct | Notes |
|---|---|---|---|
| `SDKControlRequest` | `control_request` | ✅ | CLI → agent. 3 subtypes sent CLI→SDK: `can_use_tool` (permission prompt), `hook_callback` (hook dispatch), `mcp_message` (MCP JSON-RPC). Fields: `request_id`, `request` (inner) |
| `SDKControlCancelRequest` | `control_cancel_request` | ✅ | Emits `ApprovalCancelled` to clear stale approval cards. Fields: `request_id` |
| `SDKControlResponse` | `control_response` | ✅ | Resolves pending oneshot channels for control requests. Fields: `response.subtype` ("success"/"error"), `response.request_id`, `response.response?`, `response.error?`, `response.pending_permission_requests?` |
| `SDKKeepAliveMessage` | `keep_alive` | ✅ (no-op) | Heartbeat, ignored. No fields beyond `type` |

### Internal CLI Messages (silently skipped by SDK)

| Type | `type` field | Direct | Notes |
|---|---|---|---|
| `SDKStreamlinedTextMessage` | `streamlined_text` | — | Internal; SDK skips with `continue`. Fields: `text`, `uuid` |
| `SDKStreamlinedToolUseSummaryMessage` | `streamlined_tool_use_summary` | — | Internal; SDK skips with `continue`. Fields: `tool_summary`, `uuid` |

### Duplicate Routing

| Type | `type` field | Direct | Notes |
|---|---|---|---|
| `status` (top-level) | `status` | ✅ | Duplicate path for `permissionMode` — also handled via `system` subtype `status`. Both paths emit `PermissionModeChanged` |

---

## Control Requests (OrbitDock → CLI via stdin)

These are `ControlRequestBody` variants sent as `StdinMessage::ControlRequest`. All 17 subtypes from the SDK:

### SDK → CLI Direction (we send these)

| SDK Control Request | `subtype` | Implemented | Notes |
|---|---|---|---|
| `SDKControlInitializeRequest` | `initialize` | ✅ | Sent on startup; returns session config + model list. All SDK fields wired: `systemPrompt?`, `appendSystemPrompt?`, `promptSuggestions?` (default: true), `hooks?`, `sdkMcpServers?`, `jsonSchema?`, `agents?`. Response: `commands[]`, `output_style`, `available_output_styles[]`, `models[]`, `account` |
| `SDKControlInterruptRequest` | `interrupt` | ✅ | Sent via `ClaudeAction::Interrupt`. No fields. |
| `SDKControlSetModelRequest` | `set_model` | ✅ | Via `ClaudeAction::SetModel`. Fields: `model?` (undefined = default) |
| `SDKControlSetMaxThinkingTokensRequest` | `set_max_thinking_tokens` | ✅ | Via `ClaudeAction::SetMaxThinking`. Fields: `max_thinking_tokens` (number/null). **Deprecated by SDK** — use `thinking` option instead |
| `SDKControlSetPermissionModeRequest` | `set_permission_mode` | ✅ | Via `ClaudeAction::SetPermissionMode`. Fields: `mode` ("default"/"acceptEdits"/"bypassPermissions"/"plan"/"dontAsk") |
| `SDKControlRewindFilesRequest` | `rewind_files` | ✅ | Via `ClaudeAction::RewindFiles`. Fields: `user_message_id`, `dry_run?`. Response: `canRewind`, `error?`, `filesChanged?`, `insertions?`, `deletions?`. **Note:** Works without `enableFileCheckpointing` env var when using CLI mode |
| `SDKControlStopTaskRequest` | `stop_task` | ✅ | Via `ClaudeAction::StopTask`. Fields: `task_id`. Emits `task_notification` with status "stopped" |
| `SDKControlMcpStatusRequest` | `mcp_status` | ✅ | Via `ClaudeAction::ListMcpTools`; response parsed into McpToolsList. No fields. Response: `mcpServers[]` with status (connected/failed/needs-auth/pending/disabled) |
| `SDKControlMcpReconnectRequest` | `mcp_reconnect` | ✅ | Via `ClaudeAction::RefreshMcpServer`. Fields: `serverName` |
| `SDKControlMcpToggleRequest` | `mcp_toggle` | ✅ | Via `ClaudeAction::McpToggle` + REST `POST /api/sessions/{id}/mcp/toggle`. Fields: `serverName`, `enabled` |
| `SDKControlMcpSetServersRequest` | `mcp_set_servers` | ✅ | Via `ClaudeAction::McpSetServers` + REST `POST /api/sessions/{id}/mcp/servers`. Fields: `servers` (Record). Response: `added[]`, `removed[]`, `errors[].name`, `errors[].error` |
| `SDKControlMcpMessageRequest` | `mcp_message` | ⚠️ | ControlRequestBody exists but no REST endpoint (requires SDK MCP server hosting). Fields: `server_name`, `message` (JSONRPCMessage) |
| `SDKControlMcpAuthenticateRequest` | `mcp_authenticate` | ✅ | Via `ClaudeAction::McpAuthenticate` + REST `POST /api/sessions/{id}/mcp/authenticate`. Fields: `serverName` |
| `SDKControlMcpClearAuthRequest` | `mcp_clear_auth` | ✅ | Via `ClaudeAction::McpClearAuth` + REST `POST /api/sessions/{id}/mcp/clear-auth`. Fields: `serverName` |
| `SDKControlApplyFlagSettingsRequest` | `apply_flag_settings` | ✅ | Via `ClaudeAction::ApplyFlagSettings` + REST `POST /api/sessions/{id}/flags`. Fields: `settings` (Record) |

### CLI → SDK Direction (CLI sends these to us)

| SDK Control Request | `subtype` | Implemented | Notes |
|---|---|---|---|
| `SDKControlPermissionRequest` | `can_use_tool` | ✅ | CLI asks if tool is allowed. Fields: `tool_name`, `input`, `permission_suggestions?`, `blocked_path?`, `decision_reason?`, `tool_use_id`, `agent_id?`, `description?`. Response: `{ behavior: "allow", updatedInput?, updatedPermissions?, toolUseID }` or `{ behavior: "deny", message, interrupt?, toolUseID }` |
| `SDKHookCallbackRequest` | `hook_callback` | ✅ | Handled in `handle_cli_control_request` — responds with empty `hookResults` (no hooks registered). Infrastructure ready for future hook registration via `initialize.hooks`. Fields: `callback_id`, `input` (HookInput), `tool_use_id?` |
| `SDKControlMcpMessageRequest` | `mcp_message` | ✅ | Handled in `handle_cli_control_request` — responds with error (no SDK MCP servers hosted). Infrastructure ready for future `sdkMcpServers` in `initialize`. Fields: `server_name`, `message` (JSONRPCMessage) |

---

## CLI Spawn Arguments

Flags passed to `claude` when spawning a direct session (`ClaudeConnector::new()`).

### Currently Used

| Flag | Always | Conditional | Notes |
|---|---|---|---|
| `--output-format stream-json` | ✅ | — | NDJSON stdout protocol |
| `--verbose` | ✅ | — | Enables all message types on stdout |
| `--input-format stream-json` | ✅ | — | NDJSON stdin protocol |
| `--permission-prompt-tool stdio` | ✅ | — | Routes approvals through stdin/stdout control protocol |
| `--model <model>` | — | ✅ | If model specified |
| `--resume <id>` | — | ✅ | If resuming a session |
| `--permission-mode <mode>` | — | ✅ | If mode specified. Choices: `acceptEdits`, `bypassPermissions`, `default`, `dontAsk`, `plan` |
| `--allowedTools <tools>` | — | ✅ | Comma-separated tool list |
| `--disallowedTools <tools>` | — | ✅ | Comma-separated tool list |
| `--effort <level>` | — | ✅ | If effort specified. Choices: `low`, `medium`, `high`, `max` |
| `--replay-user-messages` | ✅ | — | Re-emit synthetic user messages (tool results) on stdout — required for tool output + completion |
| `CLAUDE_CODE_ENTRYPOINT=orbitdock` | ✅ | — | Env var identifying the launcher |

### Available but Not Yet Used

These flags exist in the CLI (verified in SDK source) and could be useful:

| Flag | Takes Value | Use Case |
|---|---|---|
| `--session-id <uuid>` | UUID | Pin a specific session ID instead of auto-generating |
| `--fork-session` | boolean | Fork on resume instead of reusing original session ID |
| `--thinking <mode>` | `enabled`/`adaptive`/`disabled` | Control extended thinking behavior |
| `--max-turns <N>` | number | Auto-stop after N turns |
| `--max-budget-usd <N>` | number | Hard spend cap |
| `--fallback-model <model>` | model ID | Automatic fallback on overload |
| `--system-prompt <prompt>` | string | Custom system prompt (hidden flag) |
| `--append-system-prompt <prompt>` | string | Append to default system prompt (hidden flag) |
| `--mcp-config <configs...>` | JSON file(s) | Load MCP servers at spawn time |
| `--add-dir <dirs...>` | path(s) | Additional directories for tool access |
| `--tools <tools...>` | tool list | Restrict base tool set (`""` = none, `"default"` = all) |
| `--betas <betas...>` | beta IDs | Enable beta features (e.g. `context-1m-2025-08-07`) |
| `--include-partial-messages` | boolean | Emit `stream_event` messages (we already handle these) |
| `--disable-slash-commands` | boolean | Disable all skills |
| `--settings <file-or-json>` | JSON | Load additional settings |
| `--no-session-persistence` | boolean | Don't save session to disk |
| `--dangerously-skip-permissions` | boolean | Bypass all permission checks (sandboxed environments only) |
| `--agent <name>` | agent ID | Use a specific agent |
| `--agents <json>` | JSON | Define custom agents |
| `--plugin-dir <paths...>` | path(s) | Load plugins from directories |

### SDK-Only Options (NOT CLI Flags)

These are programmatic `Options` properties that cannot be passed as CLI flags:

| Option | Mechanism | Notes |
|---|---|---|
| `enableFileCheckpointing` | `CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING=true` env var | ✅ Set on subprocess spawn. Enables `rewind_files` file tracking + `files_persisted` events |
| `systemPrompt` (object form) | `initialize` control request | When passed as `{ type: 'preset', preset: 'claude_code', append?: string }`, sent via stdin protocol |
| `agents` | `initialize` control request | Custom agent definitions, sent via stdin protocol |
| `hooks` | `initialize` control request | Hook callback registrations, sent via stdin protocol as callback IDs |
| `promptSuggestions` | `initialize` control request | Enable prompt suggestions, sent via stdin protocol |
| `canUseTool` | SDK-side handler | Permission callback; in CLI mode, `--permission-prompt-tool stdio` achieves the same via control protocol |

---

## ClaudeAction Variants (Server → Connector)

Actions dispatched from WS handlers and REST endpoints to the Claude session event loop.

| Action | Dispatched from | Notes |
|---|---|---|
| `SendMessage` | WS `sendMessage` | Sends user message via stdin |
| `Interrupt` | WS `interruptSession` | Special handling in event loop (spawns watchdog) |
| `ApproveTool` | WS `approveTool` | Sends control_response with decision + optional updated_input |
| `AnswerQuestion` | WS `answerQuestion` | Sends control_response with structured HashMap answers |
| `Compact` | WS `compactContext` | Sends `/compact` as slash command |
| `Undo` | WS `undoLastTurn` | Sends `/undo` as slash command |
| `Resume` | — | Handled at spawn time (--resume flag); action is no-op |
| `Fork` | — | Handled at spawn time; action is no-op |
| `SetModel` | WS `setModel` | Sends set_model control request |
| `SetMaxThinking` | WS `setMaxThinking` | Sends set_max_thinking_tokens control request |
| `SetPermissionMode` | WS `setPermissionMode` | Sends set_permission_mode control request |
| `SteerTurn` | WS `steerTurn` | Enqueues user message (no interrupt) |
| `RewindFiles` | WS `rewindFiles` + event loop | Calls rewind_files control request; emits Undo events. WS dispatch wired. |
| `StopTask` | WS `stopTask` + event loop | Calls stop_task control request. WS dispatch wired. |
| `ListMcpTools` | REST `GET /api/sessions/{id}/mcp/tools` | Special handling in event loop; parses mcp_status response |
| `RefreshMcpServer` | REST `POST /api/sessions/{id}/mcp/refresh` | Calls mcp_reconnect control request |
| `McpToggle` | REST `POST /api/sessions/{id}/mcp/toggle` | Calls mcp_toggle control request |
| `McpAuthenticate` | REST `POST /api/sessions/{id}/mcp/authenticate` | Calls mcp_authenticate control request |
| `McpClearAuth` | REST `POST /api/sessions/{id}/mcp/clear-auth` | Calls mcp_clear_auth control request |
| `McpSetServers` | REST `POST /api/sessions/{id}/mcp/servers` | Calls mcp_set_servers control request |
| `ApplyFlagSettings` | REST `POST /api/sessions/{id}/flags` | Calls apply_flag_settings control request |
| `EndSession` | WS `endSession` | Kills the subprocess |

---

## ConnectorEvent Coverage

Which `ConnectorEvent` variants the Claude connector actually emits.

| Event | Emitted by Claude | Source |
|---|---|---|
| `TurnStarted` | ✅ | First `assistant` or `stream_event` message |
| `TurnCompleted` | ✅ | `result` with success subtype |
| `TurnAborted` | ✅ | `result` with error subtype, or interrupt watchdog |
| `MessageCreated` | ✅ | `assistant` (text/tool_use blocks), `user`, `task_started`, `tool_use_summary` |
| `MessageUpdated` | ✅ | `tool_progress`, `task_progress`, `task_notification`, streaming flush |
| `ApprovalRequested` | ✅ | `control_request` with `can_use_tool` |
| `ApprovalCancelled` | ✅ | `control_cancel_request` |
| `PermissionModeChanged` | ✅ | `status` message with `permissionMode` |
| `TokensUpdated` | ✅ | `result` message with usage data |
| `DiffUpdated` | ✅ | Aggregated patch diffs from Edit/Write tool_use blocks during assistant turns |
| `PlanUpdated` | ❌ | Not emitted — plan content arrives via `assistant` text blocks instead |
| `ThreadNameUpdated` | ❌ | Not applicable — AI naming handled server-side via hooks |
| `SessionEnded` | ✅ | stdout EOF, CLI exit, or read error |
| `SkillsList` | ❌ | Not emitted — skills listed via `init` system message only |
| `RemoteSkillsList` | ❌ | Not applicable — Codex-only |
| `RemoteSkillDownloaded` | ❌ | Not applicable — Codex-only |
| `SkillsUpdateAvailable` | ❌ | Not applicable — Codex-only |
| `McpToolsList` | ✅ | Emitted from event loop after mcp_status response parsing |
| `McpStartupUpdate` | ✅ | Parsed from init `mcp_servers[]` field — emits per-server status (ready/failed/needs-auth/connecting) |
| `McpStartupComplete` | ✅ | Emitted after all McpStartupUpdate events from init |
| `ClaudeInitialized` | ✅ | `system` init message |
| `ModelUpdated` | ✅ | `system` init message |
| `ContextCompacted` | ✅ | `system` compact_boundary |
| `HookSessionId` | ✅ | `system` hook_started |
| `UndoStarted` | ✅ | Emitted before rewind_files request |
| `UndoCompleted` | ✅ | Emitted after rewind_files response |
| `ThreadRolledBack` | ❌ | Not applicable — Claude uses rewind_files, not turn rollback |
| `RateLimitEvent` | ✅ | `rate_limit_event` message → broadcasts to Swift `RateLimitBanner` |
| `PromptSuggestion` | ✅ | `prompt_suggestion` message → broadcasts to Swift suggestion chips |
| `FilesPersisted` | ✅ | `system` `files_persisted` subtype → broadcasts file list to clients |
| `EnvironmentChanged` | ❌ | Not emitted from connector — handled by hooks (UserPromptSubmit re-resolves git info) |
| `Error` | ✅ | Various failure paths |

---

## Passive Session (Hook-Based) Capabilities

Passive sessions receive data via HTTP POST hooks from the Claude CLI. They cannot control the session — only observe it.

### Hook Types Handled

| Hook Type | `type` argument | What it provides |
|---|---|---|
| `claude_session_start` | `ClaudeSessionStart` | cwd, model, source, transcript_path, permission_mode, agent_type, terminal info |
| `claude_session_end` | `ClaudeSessionEnd` | reason; extracts AI summary from transcript |
| `claude_status_event` | `ClaudeStatusEvent` | hook_event_name (UserPromptSubmit, Stop, Notification, PreCompact, TeammateIdle, TaskCompleted, ConfigChange), tool_name, prompt, permission_mode |
| `claude_tool_event` | `ClaudeToolEvent` | hook_event_name (PreToolUse, PostToolUse, PostToolUseFailure, PermissionRequest), tool_name, tool_input, tool_use_id, permission_suggestions |
| `claude_subagent_event` | `ClaudeSubagentEvent` | hook_event_name (SubagentStart, SubagentStop), agent_id, agent_type, transcript_path |

### What Passive Sessions Get vs Don't Get

| Feature | Passive | Direct | Notes |
|---|---|---|---|
| Session lifecycle | ✅ | ✅ | Both track start/end |
| Work status transitions | ✅ | ✅ | Passive via hook_event_name; Direct via state machine |
| Conversation messages | ✅ (transcript sync) | ✅ (real-time) | Passive: periodic JSONL file reads. Direct: streaming |
| Tool approvals | ✅ (hook-based) | ✅ (stdio-based) | Passive: synthesized request_id. Direct: real request_id from CLI |
| Tool progress | ❌ | ✅ | Only available via stdout stream |
| Streaming content | ❌ | ✅ | Real-time character-by-character updates |
| Token usage | ❌ | ✅ | Only available from `result` message |
| Task/subagent progress | ❌ | ✅ (task_progress) | Passive only gets start/stop via hooks |
| Subagent lifecycle | ✅ | ✅ | Both track via hooks; Direct also gets task_started/notification |
| MCP management | ❌ | ✅ | Requires control requests |
| Rewind files | ❌ | ✅ | Requires control requests |
| Stop tasks | ❌ | ✅ | Requires control requests |
| Send messages | ❌ | ✅ | Requires stdin |
| Interrupt | ❌ | ✅ | Requires control requests |
| Model/config changes | ❌ | ✅ | Requires control requests |
| Git info refresh | ✅ | ✅ | Passive: on every UserPromptSubmit hook. Direct: via hooks routed to owning session |
| AI naming | ✅ | ✅ | Both trigger on first prompt |
| Summary extraction | ✅ | ✅ | Both extract from transcript on Stop/end |
| Compact count | ✅ | ✅ | Passive: PreCompact hook. Direct: hooks routed to owning session |
| Permission mode | ✅ | ✅ | Passive: from hook field. Direct: from status message + hook |
| Plan mode badge | ✅ | ✅ | Via permission_mode field |

### Managed Thread Routing

When a direct Claude session is active, hooks still fire but are **routed to the owning session** via `is_managed_claude_thread()` / `resolve_claude_thread()`. Hooks provide supplementary data that the direct connector doesn't capture:
- **Stop hook**: Summary extraction from transcript
- **PreCompact hook**: compact_count increment
- **PreToolUse hook**: last_tool tracking + DB persistence
- **PermissionRequest hook**: Skipped for approval (connector handles it) — only persists metadata
- **PostToolUse/PostToolUseFailure**: Resolves any stale pending approvals + tool_count increment
- **SubagentStart/SubagentStop**: Persists subagent records to DB + tracks active_subagent_id

---

## User Message Format (stdin)

When sending a user message via stdin, the format is:

```json
{
    "type": "user",
    "session_id": "",
    "message": {
        "role": "user",
        "content": [{ "type": "text", "text": "<message text>" }]
    },
    "parent_tool_use_id": null
}
```

Fields: `type` ("user"), `session_id` (can be ""), `message` (Anthropic MessageParam), `parent_tool_use_id` (null for top-level), `isSynthetic?`, `tool_use_result?`, `uuid?`.

**Important:** `isSynthetic` is `q.isMeta || q.isVisibleInTranscriptOnly` in the SDK. Normal tool result messages do NOT set `isMeta`, so `isSynthetic` is `false` for them. To identify tool result messages, check for `tool_result` content blocks in `message.content` instead of relying on `isSynthetic`.

---

## Control Response Format (stdin)

When responding to a `control_request` from the CLI (e.g. tool approval):

```json
{
    "type": "control_response",
    "response": {
        "subtype": "success",
        "request_id": "<original_request_id>",
        "response": { ... }
    }
}
```

Error responses:
```json
{
    "type": "control_response",
    "response": {
        "subtype": "error",
        "request_id": "<original_request_id>",
        "error": "<error message>",
        "pending_permission_requests": []
    }
}
```

The `pending_permission_requests` field can piggyback additional `can_use_tool` requests that accumulated while a previous request was being processed.

---

## Initialize Control Request

Sent once at startup. This is the richest control request — we currently send a minimal version:

```json
{
    "type": "control_request",
    "request_id": "<id>",
    "request": {
        "subtype": "initialize"
    }
}
```

Full fields we could send:

| Field | Type | Notes |
|---|---|---|
| `hooks` | `Record<HookEvent, HookCallbackMatcher[]>` | Register SDK hook callbacks (e.g. PreToolUse). CLI calls back via `hook_callback` control request |
| `sdkMcpServers` | `string[]` | Names of MCP servers the SDK hosts. CLI routes `mcp_message` requests to us for these |
| `jsonSchema` | `Record<string, unknown>` | JSON schema for structured output validation |
| `systemPrompt` | `string` | Override system prompt |
| `appendSystemPrompt` | `string` | Append to default system prompt |
| `agents` | `Record<string, AgentDefinition>` | Custom subagent definitions |
| `promptSuggestions` | `boolean` | Enable `prompt_suggestion` messages after each turn |

Response fields:

| Field | Type | Notes |
|---|---|---|
| `commands` | `SlashCommand[]` | Available slash commands/skills |
| `output_style` | `string` | Current output style |
| `available_output_styles` | `string[]` | All available output styles |
| `models` | `ModelInfo[]` | Available models with display names |
| `account` | `AccountInfo` | Authenticated account (email, org, subscription) |

---

## Not Yet Implemented (Gaps)

### High Priority
- **WS dispatch for `StopTask`** — Action exists but no `ClientMessage` handler wires it from WS
- **WS dispatch for `RewindFiles`** — Event loop handles it but no WS message triggers it (only available if called from code)
- **`RollbackTurns` for Claude** — Only dispatches to Codex; Claude would need user_message_id resolution to use rewind_files

### Medium Priority
- **`mcp_toggle` UI dispatch** — Method exists but no REST/WS endpoint exposes it
- **`mcp_set_servers`** — Dynamic MCP server management (response: added/removed/errors)
- **`mcp_authenticate` / `mcp_clear_auth`** — MCP OAuth flow
- **`McpStartupUpdate`/`McpStartupComplete`** — Could parse from init `mcp_servers[]` array (each entry has `name` + `status`)
- **`rate_limit_event` UI surfacing** — Currently logged only; rich data available (utilization, resets, overage status). Could show usage gauge or toast
- **`prompt_suggestion` UI** — Could show suggested follow-up prompts after each turn
- **`hook_progress`/`hook_response` routing** — Hook lifecycle events (could show hook execution progress in UI)
- **`enableFileCheckpointing` via env var** — Set `CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING=true` on subprocess for proper file checkpoint tracking
- **Richer `initialize` request** — We send bare `{ subtype: "initialize" }`. Could pass `systemPrompt`, `appendSystemPrompt`, `agents`, `promptSuggestions`, `hooks`

### Low Priority
- **`DiffUpdated` for Claude** — CLI doesn't emit patch diffs; would need to compute from file checkpoints
- **`apply_flag_settings`** — Runtime feature flag control (merges settings into flag layer)
- **`hook_callback`** — Hook callback resolution for async hooks (requires registering hooks in `initialize`)
- **`mcp_message`** — Raw MCP JSON-RPC passthrough (requires registering `sdkMcpServers` in `initialize`)
- **`SDKFilesPersistedEvent` handling** — Currently dead code; could track which files were persisted

---

## Key Environment Variables

Useful env vars we could set on the subprocess (all verified in SDK source):

| Variable | Current | Notes |
|---|---|---|
| `CLAUDE_CODE_ENTRYPOINT` | ✅ `"orbitdock"` | Identifies us as the launcher |
| `CLAUDECODE` | ✅ removed | Prevents nesting detection |
| `CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING` | ❌ | Enables file checkpoint tracking for rewind_files |
| `CLAUDE_CODE_DISABLE_FILE_CHECKPOINTING` | — | Explicitly disables file checkpointing |
| `CLAUDE_CODE_EMIT_TOOL_USE_SUMMARIES` | — | Controls tool_use_summary message emission |
| `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION` | — | Enables prompt_suggestion messages |
| `CLAUDE_CODE_STREAMING_TEXT` | — | Controls streaming text mode |
| `CLAUDE_CODE_EFFORT_LEVEL` | — | Default effort level |
| `CLAUDE_CODE_PLAN_MODE_REQUIRED` | — | Require plan mode |
| `DISABLE_AUTO_COMPACT` | — | Disable auto context compaction |
| `CLAUDE_CODE_DISABLE_AUTO_MEMORY` | — | Disable auto memory |
| `CLAUDE_CODE_MAX_OUTPUT_TOKENS` | — | Override max output tokens |

---

## Key Files

| File | Purpose |
|---|---|
| `connector-claude/src/lib.rs` | Main connector: stdin/stdout protocol, message dispatch, control requests |
| `connector-claude/src/session.rs` | `ClaudeAction` enum + `handle_action()` dispatch |
| `connector-core/src/event.rs` | `ConnectorEvent` enum (shared by Codex + Claude) |
| `connector-core/src/transition.rs` | Pure state machine: Input → (State, Effects) |
| `server/src/claude_session.rs` | Event loop: connector events + actions + session commands |
| `server/src/hook_handler.rs` | HTTP POST hook handler (passive + managed thread routing) |
| `server/src/session_command_handler.rs` | Shared session command processing (provider-agnostic) |
| `server/src/http_api.rs` | REST endpoints (MCP, skills, etc.) with Claude fallback |
| `server/src/ws_handlers/messaging.rs` | WS message handlers (sendMessage, approve, steer, undo) |
| `server/src/ws_handlers/approvals.rs` | WS approval handlers (approveTool, answerQuestion) |
| `server/src/ws_handlers/session_lifecycle.rs` | WS session CRUD (create, end, fork) |
| `docs/node_modules/@anthropic-ai/claude-agent-sdk/sdk.d.ts` | SDK type definitions (source of truth) |
| `docs/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs` | SDK runtime (readMessages, processControlRequest, spawn args) |
| `docs/node_modules/@anthropic-ai/claude-agent-sdk/cli.js` | Full CLI source (Zod schemas, message construction, flag parsing) |
