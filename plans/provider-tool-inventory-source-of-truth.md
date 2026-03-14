# Provider Tool Inventory Source Of Truth

Last updated: March 13, 2026

This is the raw inventory doc for the two provider surfaces we need to support well:

- Codex
- Claude Agent SDK

The purpose of this file is simple:

- enumerate the real tools, tool-adjacent items, and event payloads providers emit
- identify the fields the API contract must preserve explicitly
- stop inferring semantics from weak strings and partial JSON blobs

This is not the API design doc. It is the raw source-of-truth inventory that the API design should be built from.

## Non-Negotiables

- Provider source files beat docs.
- Raw payloads are not API contracts.
- We should not parse provider-specific JSON outside provider normalization.
- If a consumer needs a field repeatedly, the server should model it explicitly.
- The inventory should be additive: if we find a new provider payload later, we add it here before we guess in the contract.

## Source Files

### Codex

- `../openai-codex/codex-rs/app-server-protocol/schema/typescript/v2/ThreadItem.ts`
- `../openai-codex/codex-rs/app-server/src/bespoke_event_handling.rs`
- `../openai-codex/codex-rs/app-server-protocol/schema/typescript/v2/CommandExecutionRequestApprovalParams.ts`
- `../openai-codex/codex-rs/app-server-protocol/schema/typescript/v2/FileChangeRequestApprovalParams.ts`
- `../openai-codex/codex-rs/app-server-protocol/schema/typescript/v2/PermissionsRequestApprovalParams.ts`
- `../openai-codex/codex-rs/app-server-protocol/schema/typescript/v2/ToolRequestUserInputQuestion.ts`
- `../openai-codex/codex-rs/app-server-protocol/schema/typescript/v2/McpToolCallProgressNotification.ts`

### Claude

- `orbitdock-server/docs/node_modules/@anthropic-ai/claude-agent-sdk/sdk-tools.d.ts`
- `orbitdock-server/docs/node_modules/@anthropic-ai/claude-agent-sdk/sdk.d.ts`
- `orbitdock-server/docs/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs`
- `orbitdock-server/docs/node_modules/@anthropic-ai/claude-agent-sdk/cli.js`

## Codex Inventory

Codex already has a much stronger app-facing semantic surface than Claude. The biggest lesson from the Codex side is that we should preserve that strength instead of flattening it back into generic tool cards.

### Thread Items

From `ThreadItem.ts`, Codex emits these user-facing item types:

- `userMessage`
- `agentMessage`
- `plan`
- `reasoning`
- `commandExecution`
- `fileChange`
- `mcpToolCall`
- `dynamicToolCall`
- `collabAgentToolCall`
- `webSearch`
- `imageView`
- `imageGeneration`
- `enteredReviewMode`
- `exitedReviewMode`
- `contextCompaction`

### Codex Tool Families

These are the tool-like or tool-adjacent families we should preserve in OrbitDock:

- Shell / command execution
- File change / patch application
- MCP tool call
- Dynamic tool call
- Collaboration / agent tool call
- Web search
- Image view
- Image generation
- Context compaction
- Review-mode transitions

### `commandExecution`

Fields:

- `id`
- `command`
- `cwd`
- `processId`
- `status`
- `commandActions`
- `aggregatedOutput`
- `exitCode`
- `durationMs`

Contract-important fields:

- exact command string
- working directory
- structured action list
- running/completed/failed status
- combined output preview
- exit code
- duration

### `fileChange`

Fields:

- `id`
- `changes`
- `status`

Contract-important fields:

- changed files
- operation kind
- patch/apply status
- diff counts
- representative hunk/snippet

### `mcpToolCall`

Fields:

- `id`
- `server`
- `tool`
- `status`
- `arguments`
- `result`
- `error`
- `durationMs`

Contract-important fields:

- MCP server name
- tool name
- typed input arguments
- typed result
- progress / duration
- error detail

Related notification:

- `McpToolCallProgressNotification`
  - `threadId`
  - `turnId`
  - `itemId`
  - `message`

### `dynamicToolCall`

Fields:

- `id`
- `tool`
- `arguments`
- `status`
- `contentItems`
- `success`
- `durationMs`

Contract-important fields:

- dynamic tool name
- typed arguments
- typed or semi-structured result content
- status and success
- duration

### `collabAgentToolCall`

Fields:

- `id`
- `tool`
- `status`
- `senderThreadId`
- `receiverThreadIds`
- `prompt`
- `agentsStates`

Related enums:

- `CollabAgentTool`
  - `spawnAgent`
  - `sendInput`
  - `resumeAgent`
  - `wait`
  - `closeAgent`
- `CollabAgentToolCallStatus`
  - `inProgress`
  - `completed`
  - `failed`
- `CollabAgentStatus`
  - `pendingInit`
  - `running`
  - `completed`
  - `errored`
  - `shutdown`
  - `notFound`

Contract-important fields:

- collab action kind
- sender/receiver thread ids
- worker prompt
- per-agent status map
- whether this is lifecycle, communication, waiting, or shutdown

This should drive worker UX directly. We should not turn this back into generic “tool output.”

### `webSearch`

Fields:

- `id`
- `query`
- `action`

Contract-important fields:

- search query
- search action phase/state

### `imageView`

Fields:

- `id`
- `path`

### `imageGeneration`

Fields:

- `id`
- `status`
- `revisedPrompt`
- `result`

### `plan`

Fields:

- `id`
- `text`

This is not a generic tool. It is its own semantic row family.

### `reasoning`

Fields:

- `id`
- `summary`
- `content`

This is also not a generic tool. It is its own message/thinking row family.

### Codex Approval / Question / Permission Payloads

These are separate, important API surfaces:

- `CommandExecutionRequestApprovalParams`
- `FileChangeRequestApprovalParams`
- `PermissionsRequestApprovalParams`
- `ToolRequestUserInputQuestion`

Contract-important fields:

- approval kind
- reason
- scope
- permission profile
- question id/header/prompt/options
- associated tool or item id

These should feed approval/question rows directly, not pass through generic tool-card logic.

## Claude Inventory

Claude is noisier and more schema-driven. The lesson from Claude is the opposite of Codex: we need to normalize aggressively on the server so consumers do not keep learning the SDK by accident.

### Tool Input / Output Union

From `sdk-tools.d.ts`, the tool schema unions include:

#### Inputs

- `AgentInput`
- `BashInput`
- `TaskOutputInput`
- `ExitPlanModeInput`
- `FileEditInput`
- `FileReadInput`
- `FileWriteInput`
- `GlobInput`
- `GrepInput`
- `TaskStopInput`
- `ListMcpResourcesInput`
- `McpInput`
- `NotebookEditInput`
- `ReadMcpResourceInput`
- `SubscribeMcpResourceInput`
- `UnsubscribeMcpResourceInput`
- `SubscribePollingInput`
- `UnsubscribePollingInput`
- `TodoWriteInput`
- `WebFetchInput`
- `WebSearchInput`
- `AskUserQuestionInput`
- `ConfigInput`
- `EnterWorktreeInput`

#### Outputs

- `AgentOutput`
- `BashOutput`
- `ExitPlanModeOutput`
- `FileEditOutput`
- `FileReadOutput`
- `FileWriteOutput`
- `GlobOutput`
- `GrepOutput`
- `TaskStopOutput`
- `ListMcpResourcesOutput`
- `McpOutput`
- `NotebookEditOutput`
- `ReadMcpResourceOutput`
- `SubscribeMcpResourceOutput`
- `UnsubscribeMcpResourceOutput`
- `SubscribePollingOutput`
- `UnsubscribePollingOutput`
- `TodoWriteOutput`
- `WebFetchOutput`
- `WebSearchOutput`
- `AskUserQuestionOutput`
- `ConfigOutput`
- `EnterWorktreeOutput`

### Claude Tool Families

These are the semantic families we should design around:

- Shell
- File read
- File write / edit / notebook edit
- Search / glob / grep / web search / web fetch
- Agent / task / worker
- Question
- Plan mode / plan exit / todo / task planning
- MCP
- Polling / resource subscription
- Config / setup / worktree

### `AgentOutput`

Observed shapes:

- completed
- async launched

Important fields:

- `agentId`
- `prompt`
- `description`
- `content`
- `status`
- `outputFile`
- `totalToolUseCount`
- `totalDurationMs`
- `totalTokens`
- `usage`

This is a first-class worker/event family, not a generic tool row.

### `BashOutput`

We still need the exact schema documented more fully, but the family is clear:

- command
- stdout/stderr or merged output
- exit status
- duration

This should map to the same shell family as Codex `commandExecution`, even if the raw shape differs.

### `FileReadOutput`

Important detail:

- it is variant-based, not just plain text
- variants include:
  - `text`
  - `image`
  - `notebook`
  - `pdf`
  - `parts`

This is exactly why downstream guessing has been breaking down. `FileRead` is not one thing.

### `FileEditOutput` / `FileWriteOutput`

These should model:

- operation kind
- target path
- content/diff result
- line or hunk context when available

### `McpOutput`

Current schema:

- `string`

Even when the raw SDK type is just a string, OrbitDock should still normalize the invocation/result contract explicitly and attach server/tool metadata.

### `ExitPlanModeInput` / `ExitPlanModeOutput`

This is a plan-mode semantic family, not a generic tool.

The contract often needs:

- plan mode state
- structured prompt / question / next action
- whether approval or exit is needed

### `AskUserQuestionInput` / `AskUserQuestionOutput`

This is another example of a semantic row family that should not be rendered through generic tool cards.

We care about:

- question prompt
- options
- selected/returned value
- whether this is blocking

### `TodoWriteInput` / `TodoWriteOutput`

Plan/todo semantics:

- todo items
- status transitions
- task list shape

### `EnterWorktreeInput` / `EnterWorktreeOutput`

Worktree lifecycle semantics:

- worktree path
- branch context
- status/result

### Claude Hook Events

From `sdk.d.ts`, the hook event union includes:

- `PreToolUse`
- `PostToolUse`
- `PostToolUseFailure`
- `Notification`
- `UserPromptSubmit`
- `SessionStart`
- `SessionEnd`
- `Stop`
- `SubagentStart`
- `SubagentStop`
- `PreCompact`
- `PermissionRequest`
- `Setup`
- `TeammateIdle`
- `TaskCompleted`
- `Elicitation`
- `ElicitationResult`
- `ConfigChange`
- `WorktreeCreate`
- `WorktreeRemove`
- `InstructionsLoaded`

These matter because some of them should surface as conversation rows, and some should not.

### Claude SDK Messages

From `sdk.d.ts`, the runtime message union includes:

- `SDKAssistantMessage`
- `SDKUserMessage`
- `SDKUserMessageReplay`
- `SDKResultMessage`
- `SDKSystemMessage`
- `SDKPartialAssistantMessage`
- `SDKCompactBoundaryMessage`
- `SDKStatusMessage`
- `SDKLocalCommandOutputMessage`
- `SDKHookStartedMessage`
- `SDKHookProgressMessage`
- `SDKHookResponseMessage`
- `SDKToolProgressMessage`
- `SDKAuthStatusMessage`
- `SDKTaskNotificationMessage`
- `SDKTaskStartedMessage`
- `SDKTaskProgressMessage`
- `SDKFilesPersistedEvent`
- `SDKToolUseSummaryMessage`
- `SDKRateLimitEvent`
- `SDKElicitationCompleteMessage`
- `SDKPromptSuggestionMessage`

This is a gold mine for OrbitDock’s runtime modeling:

- worker/task lifecycle should come from `SDKTaskStarted/Progress/Notification`
- hook surfaces should come from the hook messages directly
- streaming assistant text should treat `SDKPartialAssistantMessage` specially
- prompt suggestions and rate limit events should not be flattened into generic tool rows

## Shared OrbitDock Semantic Families

These are the families we should normalize both providers into:

- `shell`
- `file_read`
- `file_change`
- `search`
- `web`
- `agent`
- `question`
- `approval`
- `permission_request`
- `plan`
- `mcp`
- `hook`
- `handoff`
- `context`
- `generic`

## Things The Current API Is Missing

The current `tool_display.rs` is directionally correct, but it still starts too late in the pipeline.

Problems:

- it assumes `Message` + stringly `tool_name/tool_input/tool_output` is the main semantic source
- it mixes normalization, classification, summarization, and display shaping in one place
- it forces downstream consumers to keep dealing with generic tool types even when the provider already gives stronger semantics

## What The API Contract Needs

Every tool-like item should eventually expose:

- `provider`
- `family`
- `kind`
- `status`
- `title`
- `subtitle`
- `summary`
- `preview`
- `duration_ms`
- `started_at`
- `ended_at`
- `invocation`
- `result`
- `children`
- `grouping_key`
- `expandability`
- `agent_linkage`
- `approval_linkage`

Consumers should not need to:

- parse raw JSON
- infer tool family from raw names
- guess whether something is grouped
- decide whether something is a question, worker event, or generic tool

## Recommended Next Step

Use this inventory as the source for the API redesign in:

- `plans/tool-payload-api-reset-source-of-truth.md`
