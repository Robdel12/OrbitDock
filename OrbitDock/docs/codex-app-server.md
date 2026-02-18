# Codex App Server Protocol

> Source: https://developers.openai.com/codex/app-server
> Last updated: 2025-02-04

Codex app-server is the interface Codex uses to power rich clients (for example, the Codex VS Code extension). Use it when you want a deep integration inside your own product: authentication, conversation history, approvals, and streamed agent events. The app-server implementation is open source in the Codex GitHub repository ([openai/codex/codex-rs/app-server](https://github.com/openai/codex/tree/main/codex-rs/app-server)).

Treat the server as the source of truth for thread state and item status.

This protocol is optimized for real-time UI updates and high-frequency events, so expect streaming deltas and handle them efficiently (batch updates where possible, and debounce UI refreshes).

## Protocol Basics

Like [MCP](https://modelcontextprotocol.io/), `codex app-server` supports bidirectional communication and streams JSONL over stdio. The protocol is JSON-RPC 2.0, but it omits the `"jsonrpc":"2.0"` header, so clients should not enforce it.

### Requests
```json
{ "method": "thread/start", "id": 10, "params": { "model": "gpt-5.1-codex" } }
```

### Responses
```json
{ "id": 10, "result": { "thread": { "id": "thr_123" } } }
{ "id": 10, "error": { "code": 123, "message": "Something went wrong" } }
```

### Notifications (no id)
```json
{ "method": "turn/started", "params": { "turn": { "id": "turn_456" } } }
```

## Core Concepts

- **Thread**: A conversation between a user and the Codex agent. Threads contain turns.
- **Turn**: A single user request and the agent work that follows. Turns contain items and stream incremental updates.
- **Item**: A unit of input or output (user message, agent message, command runs, file change, tool call, and more).

## Thread Methods

- `thread/start` - create a new thread
- `thread/resume` - reopen an existing thread by id
- `thread/fork` - fork a thread into a new thread id
- `thread/read` - read a stored thread by id without resuming it
- `thread/list` - page through stored thread logs
- `thread/loaded/list` - list thread ids currently loaded in memory
- `thread/archive` - move a thread's log file into archived directory
- `thread/unarchive` - restore an archived thread
- `thread/rollback` - drop the last N turns from in-memory context

## Turn Methods

- `turn/start` - add user input to a thread and begin Codex generation
- `turn/interrupt` - request cancellation of an in-flight turn

### Turn Start Parameters

The `input` field accepts a list of items:
- `{ "type": "text", "text": "Explain this diff" }`
- `{ "type": "image", "url": "https://.../design.png" }`
- `{ "type": "localImage", "path": "/tmp/screenshot.png" }`

You can override configuration settings per turn (model, effort, cwd, sandbox policy, summary).

## Event Notifications

After you start or resume a thread, keep reading stdout for notifications.

### Turn Events

- `turn/started` - `{ turn }` with the turn id, empty items, and `status: "inProgress"`
- `turn/completed` - `{ turn }` where `turn.status` is `completed`, `interrupted`, or `failed`
- `turn/diff/updated` - `{ threadId, turnId, diff }` with the latest aggregated unified diff across every file change in the turn
- `turn/plan/updated` - `{ turnId, explanation?, plan }` whenever the agent shares or changes its plan

### Item Types (ThreadItem)

- `userMessage` - `{id, content}` where content is a list of user inputs
- `agentMessage` - `{id, text}` containing the accumulated agent reply
- `plan` - `{id, text}` containing proposed plan text in plan mode
- `reasoning` - `{id, summary, content}` where summary holds streamed reasoning summaries
- `commandExecution` - `{id, command, cwd, status, commandActions, aggregatedOutput?, exitCode?, durationMs?}`
- `fileChange` - `{id, changes, status}` describing proposed edits; **changes list `{path, kind, diff}`**
- `mcpToolCall` - `{id, server, tool, status, arguments, result?, error?}`
- `webSearch` - `{id, query, action?}` for web search requests

### Item Lifecycle Events

All items emit two shared lifecycle events:
- `item/started` - emits the full item when a new unit of work begins
- `item/completed` - sends the final item once work finishes; **treat this as the authoritative state**

### Item Deltas

- `item/agentMessage/delta` - appends streamed text for the agent message
- `item/plan/delta` - streams proposed plan text
- `item/reasoning/summaryTextDelta` - streams readable reasoning summaries
- `item/commandExecution/outputDelta` - streams stdout/stderr for a command
- `item/fileChange/outputDelta` - contains the tool call response of the underlying apply_patch tool call

## Approvals

Depending on settings, command execution and file changes may require approval.

### Command Execution Approvals

1. `item/started` shows the pending commandExecution item
2. `item/commandExecution/requestApproval` includes itemId, threadId, turnId, optional reason or risk
3. Client response accepts or declines
4. `item/completed` returns the final commandExecution item

### File Change Approvals

1. `item/started` emits a fileChange item with proposed changes and `status: "inProgress"`
2. `item/fileChange/requestApproval` includes itemId, threadId, turnId
3. Client response accepts or declines
4. `item/completed` returns the final fileChange item

## Token Usage

- `thread/tokenUsage/updated` - usage updates for the active thread
- Contains `tokenUsage: { total: {...}, last: {...}, modelContextWindow: int }`
- `total` = cumulative session totals
- `last` = current turn only (use for context fill percentage)

## Rate Limits

- `account/rateLimits/read` - fetch ChatGPT rate limits
- `account/rateLimits/updated` (notify) - emitted whenever rate limits change
- Fields: `usedPercent`, `windowDurationMins`, `resetsAt` (Unix timestamp)

## Error Handling

Common `codexErrorInfo` values:
- `ContextWindowExceeded`
- `UsageLimitExceeded`
- `HttpConnectionFailed` (4xx/5xx upstream errors)
- `ResponseStreamConnectionFailed`
- `ResponseStreamDisconnected`
- `ResponseTooManyFailedAttempts`
- `BadRequest`, `Unauthorized`, `SandboxError`, `InternalServerError`, `Other`

## Other Methods

- `review/start` - kick off the Codex reviewer for a thread
- `command/exec` - run a single command under the server sandbox without starting a thread/turn
- `model/list` - list available models
- `skills/list` - list skills for one or more cwd values
- `app/list` - list available apps (connectors)
- `config/read` - fetch the effective configuration
- `config/value/write` - write a single configuration key/value

## Authentication

Codex supports multiple authentication modes:
- **API key (`apikey`)** - caller supplies an OpenAI API key
- **ChatGPT managed (`chatgpt`)** - Codex owns the OAuth flow
- **ChatGPT external tokens (`chatgptAuthTokens`)** - host app supplies tokens directly

Methods:
- `account/read` - fetch current account info
- `account/login/start` - begin login
- `account/login/completed` (notify) - emitted when login finishes
- `account/logout` - sign out
- `account/updated` (notify) - emitted whenever auth mode changes
