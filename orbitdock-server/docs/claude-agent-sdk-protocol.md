# Claude Agent SDK Protocol Reference

> Reverse-engineered from `@anthropic-ai/claude-agent-sdk@0.1.77` (sdk.mjs, 21,493 lines).
> This documents the exact stdin/stdout JSON protocol the SDK uses to communicate with the `claude` CLI binary.

## Architecture

The Agent SDK does **not** call the Anthropic API directly. It spawns the `claude` CLI as a child process and communicates via stdin/stdout using newline-delimited JSON (NDJSON):

```
SDK (or our Rust connector)
    │
    ├── stdin  → JSON lines → claude CLI process
    └── stdout ← JSON lines ← claude CLI process
```

The protocol is **bidirectional** — both sides can initiate request/response exchanges using `control_request` / `control_response` messages with `request_id` matching.

---

## Spawning the CLI

### Command

```
claude --output-format stream-json --verbose --input-format stream-json [flags...]
```

The three fixed flags are always present. They put the CLI into NDJSON streaming mode.

### Optional CLI Flags

| SDK Option | CLI Flag |
|---|---|
| `model` | `--model <model>` |
| `maxThinkingTokens` | `--max-thinking-tokens <N>` |
| `maxTurns` | `--max-turns <N>` |
| `maxBudgetUsd` | `--max-budget-usd <N>` |
| `betas` | `--betas <comma-separated>` |
| `canUseTool` callback | `--permission-prompt-tool stdio` |
| `permissionPromptToolName` | `--permission-prompt-tool <name>` |
| `permissionMode` | `--permission-mode <mode>` |
| `allowDangerouslySkipPermissions` | `--allow-dangerously-skip-permissions` |
| `continue` | `--continue` |
| `resume` | `--resume <sessionId>` |
| `forkSession` | `--fork-session` |
| `resumeSessionAt` | `--resume-session-at <messageUuid>` |
| `allowedTools` | `--allowedTools <comma-separated>` |
| `disallowedTools` | `--disallowedTools <comma-separated>` |
| `tools` (array) | `--tools <comma-separated>` |
| `tools` (preset) | `--tools default` |
| `mcpServers` | `--mcp-config <JSON>` |
| `settingSources` | `--setting-sources <comma-separated>` |
| `strictMcpConfig` | `--strict-mcp-config` |
| `fallbackModel` | `--fallback-model <model>` |
| `includePartialMessages` | `--include-partial-messages` |
| `additionalDirectories` | `--add-dir <dir>` (repeated per directory) |
| `plugins` | `--plugin-dir <path>` (repeated per plugin) |
| `persistSession === false` | `--no-session-persistence` |
| `jsonSchema` | `--json-schema <JSON>` |
| `DEBUG_CLAUDE_AGENT_SDK` env | `--debug-to-stderr` |
| `extraArgs` | `--<flag> [value]` for each entry |

### Environment Variables

| Variable | Value |
|---|---|
| `CLAUDE_CODE_ENTRYPOINT` | `"sdk-ts"` (set by SDK, we should set to `"orbitdock"`) |
| `NODE_OPTIONS` | **deleted** |
| `DEBUG` | `"1"` if debug mode, otherwise **deleted** |

### Stdio Configuration

- **stdin**: piped (JSON lines from SDK to CLI)
- **stdout**: piped (JSON lines from CLI to SDK)
- **stderr**: piped if debug/stderr callback, otherwise `"ignore"`

---

## Wire Protocol

All messages are newline-delimited JSON. Each message is a single JSON object followed by `\n`.

### Stdin Messages (SDK → CLI)

```typescript
type StdinMessage =
  | SDKUserMessage        // User prompts
  | SDKControlRequest     // Control commands from SDK
  | SDKControlResponse    // Responses to CLI-initiated requests
  | SDKKeepAliveMessage   // Heartbeat (not typically sent by SDK)
```

### Stdout Messages (CLI → SDK)

```typescript
type StdoutMessage =
  | SDKMessage              // Content messages (assistant, user, result, system, etc.)
  | SDKControlResponse      // Responses to SDK-initiated requests
  | SDKControlRequest       // Requests FROM CLI (e.g., permission prompts)
  | SDKControlCancelRequest // Cancel a pending control request
  | SDKKeepAliveMessage     // Heartbeat (silently consumed by SDK)
```

---

## Message Types — Stdin (SDK → CLI)

### User Message

Sent to provide a user prompt. The first user message starts a turn.

```json
{
  "type": "user",
  "session_id": "",
  "message": {
    "role": "user",
    "content": [
      { "type": "text", "text": "What files are in this directory?" }
    ]
  },
  "parent_tool_use_id": null
}
```

Notes:
- `session_id` is always `""` (empty string) when sent from the SDK
- `parent_tool_use_id` is always `null` for top-level prompts
- `content` is an array of content blocks (text, images, etc.) following the Anthropic API `MessageParam` format
- The prompt is written to stdin **concurrently** with the `initialize` control request — the CLI buffers it

### Control Request

Generic wrapper for all control commands from SDK to CLI.

```json
{
  "type": "control_request",
  "request_id": "<random_uuid>",
  "request": {
    "subtype": "<request_type>",
    ...fields
  }
}
```

The `request_id` is used to match responses. See [Control Requests](#control-requests-sdk--cli) below for all subtypes.

### Control Response

Response to a control request initiated by the CLI (e.g., answering a permission prompt).

```json
{
  "type": "control_response",
  "response": {
    "subtype": "success",
    "request_id": "<original_request_id>",
    "response": { ...payload }
  }
}
```

Or on error:

```json
{
  "type": "control_response",
  "response": {
    "subtype": "error",
    "request_id": "<original_request_id>",
    "error": "error message"
  }
}
```

### Keep-Alive

```json
{ "type": "keep_alive" }
```

---

## Message Types — Stdout (CLI → SDK)

### System Init (`SDKSystemMessage`)

First meaningful message. Contains session metadata.

```json
{
  "type": "system",
  "subtype": "init",
  "session_id": "abc123-...",
  "model": "claude-sonnet-4-5-20250929",
  "cwd": "/path/to/project",
  "tools": ["Read", "Write", "Edit", "Bash", "Glob", "Grep", ...],
  "mcp_servers": [
    { "name": "server-name", "status": "connected" }
  ],
  "permissionMode": "default",
  "slash_commands": ["commit", "review-pr", ...],
  "skills": [...],
  "plugins": [{ "name": "...", "path": "..." }],
  "claude_code_version": "1.x.x",
  "apiKeySource": "user",
  "betas": [],
  "agents": [...],
  "output_style": "...",
  "uuid": "...",
  "session_id": "..."
}
```

### Assistant Message (`SDKAssistantMessage`)

A complete assistant response containing content blocks.

```json
{
  "type": "assistant",
  "message": {
    "id": "msg_...",
    "type": "message",
    "role": "assistant",
    "content": [
      { "type": "text", "text": "Here are the files..." },
      { "type": "tool_use", "id": "toolu_...", "name": "Bash", "input": { "command": "ls" } }
    ],
    "model": "claude-sonnet-4-5-20250929",
    "stop_reason": "tool_use",
    "usage": {
      "input_tokens": 1234,
      "output_tokens": 567,
      "cache_creation_input_tokens": 0,
      "cache_read_input_tokens": 890
    }
  },
  "parent_tool_use_id": null,
  "uuid": "...",
  "session_id": "..."
}
```

The `message` field follows the [Anthropic Messages API response format](https://docs.anthropic.com/en/api/messages).

Content block types:
- `text` — text content
- `tool_use` — tool invocation with `name` and `input`
- `thinking` — extended thinking content

### User Message Echo (`SDKUserMessage` / `SDKUserMessageReplay`)

The CLI echoes back user messages and tool results.

```json
{
  "type": "user",
  "session_id": "...",
  "message": {
    "role": "user",
    "content": [
      { "type": "tool_result", "tool_use_id": "toolu_...", "content": "file contents..." }
    ]
  },
  "parent_tool_use_id": null,
  "tool_use_result": { ... },
  "uuid": "...",
  "isSynthetic": true
}
```

For replayed messages (during resume), `isReplay: true` is set.

### Streaming Event (`SDKPartialAssistantMessage`)

Only emitted when `--include-partial-messages` is used. Contains raw Anthropic SSE events.

```json
{
  "type": "stream_event",
  "event": {
    "type": "content_block_delta",
    "index": 0,
    "delta": { "type": "text_delta", "text": "partial text..." }
  },
  "parent_tool_use_id": null,
  "uuid": "...",
  "session_id": "..."
}
```

The `event` field follows the [Anthropic streaming event format](https://docs.anthropic.com/en/api/messages-streaming).

### Result Message (`SDKResultMessage`)

Emitted when a turn completes. Contains cost and usage data.

**Success:**
```json
{
  "type": "result",
  "subtype": "success",
  "result": "Final text output from the assistant",
  "duration_ms": 12345,
  "duration_api_ms": 10000,
  "is_error": false,
  "num_turns": 3,
  "total_cost_usd": 0.05,
  "usage": {
    "input_tokens": 5000,
    "output_tokens": 2000,
    "cache_creation_input_tokens": 100,
    "cache_read_input_tokens": 3000
  },
  "modelUsage": {
    "claude-sonnet-4-5-20250929": {
      "inputTokens": 5000,
      "outputTokens": 2000,
      "cacheReadInputTokens": 3000,
      "cacheCreationInputTokens": 100,
      "webSearchRequests": 0,
      "costUSD": 0.05,
      "contextWindow": 200000
    }
  },
  "permission_denials": [],
  "uuid": "...",
  "session_id": "..."
}
```

**Error subtypes:**
- `"error_during_execution"` — runtime error
- `"error_max_turns"` — hit max turns limit
- `"error_max_budget_usd"` — hit budget limit
- `"error_max_structured_output_retries"` — structured output validation failed

Error results include an `errors: string[]` field instead of `result`.

### Compact Boundary (`SDKCompactBoundaryMessage`)

```json
{
  "type": "system",
  "subtype": "compact_boundary",
  "compact_metadata": {
    "trigger": "manual",
    "pre_tokens": 150000
  },
  "uuid": "...",
  "session_id": "..."
}
```

### Status (`SDKStatusMessage`)

```json
{
  "type": "system",
  "subtype": "status",
  "status": "compacting",
  "uuid": "...",
  "session_id": "..."
}
```

`status` is `"compacting"` or `null`.

### Tool Progress (`SDKToolProgressMessage`)

Periodic progress updates during long-running tool executions.

```json
{
  "type": "tool_progress",
  "tool_use_id": "toolu_...",
  "tool_name": "Bash",
  "parent_tool_use_id": null,
  "elapsed_time_seconds": 15,
  "uuid": "...",
  "session_id": "..."
}
```

### Hook Response (`SDKHookResponseMessage`)

```json
{
  "type": "system",
  "subtype": "hook_response",
  "hook_name": "my-hook",
  "hook_event": "PreToolUse",
  "stdout": "hook output",
  "stderr": "",
  "exit_code": 0,
  "uuid": "...",
  "session_id": "..."
}
```

### Auth Status (`SDKAuthStatusMessage`)

```json
{
  "type": "auth_status",
  "isAuthenticating": true,
  "output": ["Authenticating..."],
  "error": null,
  "uuid": "...",
  "session_id": "..."
}
```

### Keep-Alive

```json
{ "type": "keep_alive" }
```

Silently consumed. The CLI sends these periodically. The SDK does not respond to them.

### Control Request (CLI → SDK)

The CLI can initiate requests to the SDK, primarily for permission prompts.

```json
{
  "type": "control_request",
  "request_id": "<id>",
  "request": {
    "subtype": "can_use_tool",
    ...fields
  }
}
```

See [Control Requests — CLI → SDK](#control-requests-cli--sdk) below.

### Control Cancel Request

The CLI can cancel a pending control request (e.g., if the user interrupts).

```json
{
  "type": "control_cancel_request",
  "request_id": "<original_request_id>"
}
```

---

## Control Requests (SDK → CLI)

All control requests follow the same envelope:

```json
{
  "type": "control_request",
  "request_id": "<random_id>",
  "request": { "subtype": "<type>", ...fields }
}
```

The CLI responds with a `control_response` on stdout with matching `request_id`.

### `initialize`

Sent immediately after spawning. Configures the session.

```json
{
  "subtype": "initialize",
  "hooks": {
    "PreToolUse": [{ "matcher": "...", "hookCallbackIds": ["hook_0"], "timeout": 30 }],
    "PostToolUse": [{ "hookCallbackIds": ["hook_1"] }]
  },
  "sdkMcpServers": ["server-name"],
  "jsonSchema": { "type": "object", "properties": { ... } },
  "systemPrompt": "custom system prompt",
  "appendSystemPrompt": "appended to default prompt",
  "agents": {
    "test-runner": {
      "description": "Runs tests",
      "prompt": "You are a test runner...",
      "tools": ["Bash", "Read"]
    }
  }
}
```

**Response payload:**
```json
{
  "commands": [{ "name": "commit", "description": "...", "argumentHint": "" }],
  "output_style": "...",
  "available_output_styles": ["..."],
  "models": [{ "value": "claude-sonnet-4-5-20250929", "displayName": "Sonnet 4.5", "description": "..." }],
  "account": { "email": "...", "organization": "...", "subscriptionType": "..." }
}
```

### `interrupt`

Interrupt the current turn.

```json
{ "subtype": "interrupt" }
```

Response is a simple success acknowledgment.

### `set_model`

Change the model mid-session.

```json
{
  "subtype": "set_model",
  "model": "claude-opus-4-20250514"
}
```

Pass `model: undefined` to reset to default.

### `set_max_thinking_tokens`

Change the thinking token budget.

```json
{
  "subtype": "set_max_thinking_tokens",
  "max_thinking_tokens": 50000
}
```

Pass `null` to clear the limit.

### `set_permission_mode`

Change permission mode mid-session.

```json
{
  "subtype": "set_permission_mode",
  "mode": "acceptEdits"
}
```

Modes: `"default"`, `"acceptEdits"`, `"bypassPermissions"`, `"plan"`, `"delegate"`, `"dontAsk"`.

### `mcp_status`

Query MCP server connection status.

```json
{ "subtype": "mcp_status" }
```

Response: array of `{ name, status, serverInfo? }`.

### `mcp_set_servers`

Dynamically add/remove MCP servers.

```json
{
  "subtype": "mcp_set_servers",
  "servers": {
    "my-server": {
      "type": "stdio",
      "command": "node",
      "args": ["./server.js"]
    }
  }
}
```

Response: `{ added: [...], removed: [...], errors: {...} }`.

### `mcp_message`

Send a JSON-RPC message to a specific MCP server.

```json
{
  "subtype": "mcp_message",
  "server_name": "my-server",
  "message": { "jsonrpc": "2.0", "method": "...", "params": {...}, "id": 1 }
}
```

### `rewind_files`

Rewind files to their state at a specific user message.

```json
{
  "subtype": "rewind_files",
  "user_message_id": "<uuid>",
  "dry_run": true
}
```

Response: `{ canRewind, error?, filesChanged?, insertions?, deletions? }`.

---

## Control Requests (CLI → SDK)

The CLI sends these on stdout. The SDK must respond on stdin with a `control_response`.

### `can_use_tool` (Permission Request)

The CLI asks for permission before executing a tool.

```json
{
  "type": "control_request",
  "request_id": "req_abc123",
  "request": {
    "subtype": "can_use_tool",
    "tool_name": "Bash",
    "input": { "command": "rm -rf /tmp/test" },
    "permission_suggestions": [
      {
        "type": "addRules",
        "rules": [{ "toolName": "Bash", "ruleContent": "rm *" }],
        "behavior": "allow",
        "destination": "session"
      }
    ],
    "blocked_path": "/etc/passwd",
    "decision_reason": "Command accesses path outside allowed directories",
    "tool_use_id": "toolu_abc123",
    "agent_id": "agent_xyz"
  }
}
```

**Allow response:**
```json
{
  "type": "control_response",
  "response": {
    "subtype": "success",
    "request_id": "req_abc123",
    "response": {
      "behavior": "allow",
      "updatedInput": { "command": "rm -rf /tmp/test" },
      "updatedPermissions": [
        {
          "type": "addRules",
          "rules": [{ "toolName": "Bash", "ruleContent": "rm *" }],
          "behavior": "allow",
          "destination": "session"
        }
      ],
      "toolUseID": "toolu_abc123"
    }
  }
}
```

**Deny response:**
```json
{
  "type": "control_response",
  "response": {
    "subtype": "success",
    "request_id": "req_abc123",
    "response": {
      "behavior": "deny",
      "message": "User denied this operation",
      "interrupt": true,
      "toolUseID": "toolu_abc123"
    }
  }
}
```

Permission result fields:
- `behavior`: `"allow"` or `"deny"`
- `updatedInput`: (allow only) Modified tool input, if any
- `updatedPermissions`: (allow only) Permission rule updates to apply (e.g., "always allow")
- `message`: (deny only) Reason for denial or guidance
- `interrupt`: (deny only) If true, stop the turn entirely
- `toolUseID`: Echo back the tool_use_id

### `hook_callback`

The CLI invokes a registered hook callback.

```json
{
  "type": "control_request",
  "request_id": "req_hook_1",
  "request": {
    "subtype": "hook_callback",
    "callback_id": "hook_0",
    "input": {
      "session_id": "...",
      "transcript_path": "...",
      "cwd": "...",
      "hook_event_name": "PreToolUse",
      "tool_name": "Bash",
      "tool_input": { "command": "..." },
      "tool_use_id": "toolu_..."
    },
    "tool_use_id": "toolu_..."
  }
}
```

Response should contain the hook output (continue, suppress, etc.).

### `mcp_message`

The CLI routes an MCP message to an SDK-hosted MCP server.

```json
{
  "type": "control_request",
  "request_id": "req_mcp_1",
  "request": {
    "subtype": "mcp_message",
    "server_name": "my-sdk-server",
    "message": { "jsonrpc": "2.0", ... }
  }
}
```

---

## Session Lifecycle

### Single-Turn (query with string prompt)

```
1. Spawn: claude --output-format stream-json --verbose --input-format stream-json [flags]
2. SDK→stdin: control_request { initialize }
3. SDK→stdin: user message { prompt text }
4. CLI→stdout: control_response { init result: commands, models, account }
5. CLI→stdout: system { init: session_id, tools, model, ... }
6. CLI→stdout: assistant { message with content blocks }
7. CLI→stdout: [control_request { can_use_tool }]     ← if permission needed
8. SDK→stdin: [control_response { allow/deny }]        ← response to permission
9. CLI→stdout: user { tool results (synthetic) }
10. CLI→stdout: assistant { next response }
11. ... (tool loop continues)
12. CLI→stdout: result { success, cost, usage }
13. SDK closes stdin → CLI exits
```

### Multi-Turn (V2 Session API)

```
1. Spawn: claude --output-format stream-json --verbose --input-format stream-json [flags]
2. SDK→stdin: control_request { initialize }
3. SDK→stdin: user message { first prompt }
4. CLI→stdout: control_response { init result }
5. CLI→stdout: system { init }
6. ... (messages flow, tool loops, etc.)
7. CLI→stdout: result { first turn complete }
8.                                              ← stdin stays OPEN
9. SDK→stdin: user message { second prompt }    ← new turn
10. CLI→stdout: assistant { ... }
11. ... (more tool loops)
12. CLI→stdout: result { second turn complete }
13. SDK→stdin: user message { third prompt }    ← another turn
14. ...
15. SDK closes stdin (or calls close()) → CLI exits
```

### Resume

```
1. Spawn: claude --output-format stream-json --verbose --input-format stream-json --resume <session_id> [flags]
2. SDK→stdin: control_request { initialize }
3. SDK→stdin: user message { new prompt }
4. CLI→stdout: control_response { init result }
5. CLI→stdout: system { init } (with original session_id)
6. CLI→stdout: user { replayed messages from history, isReplay: true }
7. CLI→stdout: assistant { replayed messages }
8. ... (history replay)
9. CLI→stdout: assistant { new response to new prompt }
10. ... (normal flow)
```

### Fork

```
1. Spawn: claude ... --resume <session_id> --fork-session [--resume-session-at <uuid>]
2. Same as resume, but CLI creates a new session_id branching from the original
```

---

## Key Implementation Details

### Prompt Timing

The user prompt is written to stdin **concurrently** with the `initialize` control request. The CLI buffers the user message until initialization completes on its end. This is safe because stdin is a pipe buffer.

### Request/Response Matching

Control requests use randomly generated `request_id` values. Both sides maintain a map of pending requests. When a `control_response` arrives, it's matched by `request_id` to resolve the corresponding promise/future.

### Cancellation

- **From SDK**: Send `control_request { interrupt }`. The CLI acknowledges and stops the current turn.
- **From CLI**: Send `control_cancel_request { request_id }`. The SDK aborts the handler for that request (e.g., cancels a pending permission callback).
- **Process-level**: The SDK's `AbortController` sends `SIGTERM` to the child process, then `SIGKILL` after 5 seconds.

### Stdin Closing

- **Single-turn**: stdin is closed after the first `result` message is received
- **Multi-turn with bidirectional needs** (hooks, canUseTool, MCP): stdin stays open until the input stream is exhausted AND the first `result` is received
- **Multi-turn without bidirectional needs**: stdin is closed after the input stream is exhausted

For our Rust connector (multi-turn with permissions), stdin should stay open for the lifetime of the session.

### Error Handling

- Non-zero exit code: `"Claude Code process exited with code <N>"`
- Killed by signal: `"Claude Code process terminated by signal <signal>"`
- No reconnection — if the CLI dies, the session is over. Start a new process to continue.

### Pending Permissions on Error

When a control response comes back as `error` AND includes `pending_permission_requests`, those permission requests are immediately dispatched. This handles the case where the CLI sends multiple permission requests before the SDK has responded to the first one.

### Keep-Alive

The CLI sends `{"type":"keep_alive"}` periodically on stdout. The SDK silently consumes them. The SDK does not send keep-alives to the CLI.

---

## What We Need for the Rust Connector

To replace the Node.js bridge with a pure Rust implementation, we need:

1. **Spawn `claude` CLI** with `--output-format stream-json --verbose --input-format stream-json --permission-prompt-tool stdio` and any other flags
2. **Send `initialize` control request** on stdin (can be minimal: just `subtype: "initialize"`)
3. **Send user messages** as `SDKUserMessage` JSON lines on stdin
4. **Read stdout** line by line, parse JSON, dispatch by `type`:
   - `system` (init) → capture session_id, tools, model
   - `assistant` → emit as message events
   - `user` (synthetic) → emit as tool result events
   - `stream_event` → emit as streaming deltas
   - `result` → emit turn completed with usage/cost
   - `control_request` (can_use_tool) → route to permission handler, respond on stdin
   - `control_response` → match to pending request
   - `control_cancel_request` → cancel pending handler
   - `keep_alive` → ignore
   - `tool_progress` → emit progress event
   - `system` (compact_boundary) → emit compaction event
   - `system` (status) → emit status change
5. **Mid-session control**: send `set_model`, `set_max_thinking_tokens`, `interrupt` as control requests
6. **Multi-turn**: keep stdin open, send new user messages for each turn
7. **Shutdown**: close stdin or send SIGTERM

### Finding the `claude` Binary

The SDK resolves the CLI path via `pathToClaudeCodeExecutable` option, defaulting to `cli.js` bundled with the SDK. For our Rust connector, we should:

1. Check `CLAUDE_BIN` env var
2. Look in common locations: `~/.claude/local/claude`, `/usr/local/bin/claude`
3. Fall back to `which claude` equivalent (search PATH)

Since `claude` is already installed (the user is running Claude Code), this is much more reliable than finding `node`.
