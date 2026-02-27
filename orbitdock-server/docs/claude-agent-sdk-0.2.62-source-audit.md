# Claude Agent SDK Source Audit (`@anthropic-ai/claude-agent-sdk@0.2.62`)

Last audited: February 27, 2026

## 1. Canonical Source Location

- Installed package (source of truth): `orbitdock-server/docs/node_modules/@anthropic-ai/claude-agent-sdk/`
- Dependency declaration: `orbitdock-server/docs/package.json`
- Installed package version: `0.2.62`
- Embedded Claude Code version in package metadata: `2.1.62`

If behavior in docs differs from behavior in shipped code, use the shipped code.

## 2. What Is Actually Shipped

Key files in the installed package:

- `sdk.mjs` (runtime SDK wrapper, minified bundle)
- `sdk.d.ts` (typed API surface + control/message contracts)
- `sdk-tools.d.ts` (generated built-in tool input/output schemas)
- `cli.js` (full Claude Code CLI bundle used by SDK transport path)
- `manifest.json` / `manifest.zst.json` (native binary build metadata)
- `vendor/ripgrep/*` + `.wasm` assets

## 3. Public SDK Surface We Can Call

From `sdk.mjs` / `sdk.d.ts`, exported callable API is:

- `query(...)`
- `tool(...)`
- `createSdkMcpServer(...)`
- `listSessions(...)`
- `getSessionMessages(...)`
- `unstable_v2_createSession(...)`
- `unstable_v2_prompt(...)`
- `unstable_v2_resumeSession(...)`

Exported constants:

- `HOOK_EVENTS`
- `EXIT_REASONS`
- `AbortError`

## 4. Runtime Architecture (How SDK Actually Works)

`query(...)` creates a transport session that spawns Claude Code with stream JSON I/O. In `sdk.mjs`, options are translated into CLI flags, then control requests/messages are exchanged over stdio.

Relevant runtime behavior confirmed in shipped code:

- `permissionMode` maps to `--permission-mode <mode>`
- `allowDangerouslySkipPermissions` maps to `--allow-dangerously-skip-permissions`
- `allowedTools` maps to `--allowedTools ...`
- `disallowedTools` maps to `--disallowedTools ...`
- `tools` maps to `--tools ...`
- `mcpServers` maps to `--mcp-config <json>`
- `permissionPromptToolName` maps to `--permission-prompt-tool <name>`
- `canUseTool` mode uses `--permission-prompt-tool stdio`
- `canUseTool` and `permissionPromptToolName` are mutually exclusive (SDK throws if both are set)

`Query` exposes control methods including:

- `interrupt()`
- `setPermissionMode(mode)`
- `setModel(model?)`
- `setMaxThinkingTokens(number | null)` (deprecated but present)
- MCP control helpers (`mcpServerStatus`, `reconnectMcpServer`, `toggleMcpServer`, `setMcpServers`, etc.)

## 5. Permission Model (What We Truly Control)

`PermissionMode` values in shipped types:

- `default`
- `acceptEdits`
- `bypassPermissions`
- `plan`
- `dontAsk`

`CanUseTool` callback receives:

- `toolName`
- `input`
- options:
  - `signal`
  - `suggestions` (`PermissionUpdate[]`)
  - `blockedPath`
  - `decisionReason`
  - `toolUseID`
  - `agentID?`

`CanUseTool` returns `PermissionResult`:

- allow:
  - `behavior: "allow"`
  - optional `updatedInput`
  - optional `updatedPermissions`
- deny:
  - `behavior: "deny"`
  - `message`
  - optional `interrupt`

`PermissionUpdate` supports:

- `addRules`
- `replaceRules`
- `removeRules`
- `setMode`
- `addDirectories`
- `removeDirectories`

Destinations:

- `userSettings`
- `projectSettings`
- `localSettings`
- `session`
- `cliArg`

## 6. Plan Mode + `ExitPlanMode` Tool

### Plan mode behavior

In SDK types, `permissionMode: "plan"` is explicitly documented as planning mode with no actual tool execution.

### `ExitPlanMode` contract (`sdk-tools.d.ts`)

Input:

- `allowedPrompts?: { tool: "Bash"; prompt: string }[]`

Output:

- `plan: string | null`
- `isAgent: boolean`
- optional `filePath`
- optional `hasTaskTool`
- optional `awaitingLeaderApproval`
- optional `requestId`

### Runtime behavior (`cli.js`)

`ExitPlanMode` prompt text in the shipped bundle confirms:

- It should be used after writing the plan to the plan file.
- It signals readiness for approval rather than sending the plan inline.
- It is for implementation-planning workflows, not pure research/file-reading tasks.

The runtime tool implementation shows:

- Permission check is interactive ask by default (`behavior: "ask", message: "Exit plan mode?"`) unless in non-interactive team-agent path.
- On success, state exits plan mode by restoring `toolPermissionContext.mode` to prior mode.
- In teammate/team-lead flows, plan approval requests include request IDs and waiting state.

Important operational implication:

- Headless/automated callers must explicitly handle `ExitPlanMode` tool calls (and related approval flow) if plan mode is enabled.

## 7. Built-in Tool Surface (From `sdk-tools.d.ts`)

`ToolInputSchemas` union includes:

- `Agent`
- `Bash`
- `TaskOutput`
- `ExitPlanMode`
- `FileEdit`
- `FileRead`
- `FileWrite`
- `Glob`
- `Grep`
- `TaskStop`
- `ListMcpResources`
- `Mcp`
- `NotebookEdit`
- `ReadMcpResource`
- `SubscribeMcpResource`
- `UnsubscribeMcpResource`
- `SubscribePolling`
- `UnsubscribePolling`
- `TodoWrite`
- `WebFetch`
- `WebSearch`
- `AskUserQuestion`
- `Config`
- `EnterWorktree`

This is the concrete built-in tool contract we can rely on for protocol mapping.

## 8. Hook/Control Events Available

`HOOK_EVENTS` includes:

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
- `ConfigChange`
- `WorktreeCreate`
- `WorktreeRemove`

Control channel includes support for:

- permission decisions (`can_use_tool`)
- hook callback dispatch (`hook_callback`)
- MCP message pass-through (`mcp_message`)
- dynamic permission mode changes (`set_permission_mode`)

## 9. What We Do and Do Not Have Access To

We do have:

- The shipped runtime behavior (`sdk.mjs` + `cli.js`)
- Complete TypeScript declaration contracts (`sdk.d.ts`, `sdk-tools.d.ts`)
- Embedded metadata for native binaries (`manifest*.json`)

We do not have:

- Unminified upstream internal source for this exact build
- Guaranteed stable internals outside exported SDK API

For OrbitDock reverse-engineering, this local installed package is authoritative.

## 10. Updating SDK Version for Ongoing Accuracy

From `orbitdock-server/docs/`:

```bash
npm install @anthropic-ai/claude-agent-sdk@<version>
```

After upgrade:

- Re-audit `sdk.mjs`, `sdk.d.ts`, `sdk-tools.d.ts`, and `cli.js`
- Update this audit filename/version if behavior changed materially

## 11. Secondary References (Cross-check only)

- Overview: <https://platform.claude.com/docs/en/agent-sdk/overview>
- Permissions: <https://platform.claude.com/docs/en/agent-sdk/sdk-permissions>
- Handle approvals and user input: <https://platform.claude.com/docs/en/agent-sdk/handle-approvals-user-input>
- Cookbook example discussing `ExitPlanMode` in custom loop context: <https://github.com/anthropics/anthropic-cookbook/blob/main/tool_use/remote-mcp-server-with-claude-code-sdk.ipynb>

