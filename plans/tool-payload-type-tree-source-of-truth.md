# Tool Payload Type Tree Source Of Truth

Last updated: March 13, 2026

This is the concrete type-tree and execution plan for the provider tool payload reset.

This plan is API, protocol, and server only.

It exists to answer four questions clearly:

1. What are the Rust types and module boundaries?
2. How do we delete and replace the current architecture without dragging `tool_display.rs` forward?
3. How do we split the work so a lot of parallel agents can attack it safely?
4. How do we verify the contracts with outcome-focused tests?

This plan is driven by:

- `plans/provider-tool-inventory-source-of-truth.md`
- `plans/tool-payload-api-reset-source-of-truth.md`
- real provider source files, not docs
- `testing-philosophy`

## Status

- [x] Phase 0: Freeze contracts and delete legacy assumptions
- [x] Phase 1: Provider normalization layer
- [x] Phase 2: Normalized domain events
- [x] Phase 3: API conversation contracts
- [x] Phase 4: Grouping
- [x] Phase 5: Transport cutover
- [x] Phase 6: Delete legacy path
- [x] Phase 7: Outcome-focused verification

Legend:

- `[x]` done
- `[~]` in progress
- `[ ]` not started

## Current Check-In

What is actually true right now:

- provider inventory is done for both Claude and Codex
- the delete-and-replace architecture is decided
- the Rust protocol reset has started under:
  - `provider_normalization/`
  - `domain_events/`
  - `conversation_contracts/`
  - `grouping/`

What is now true:

- `Message`, `MessageType`, `classify_tool_family`, `tool_display` have been fully deleted
- `ConversationRow` is the live contract for both HTTP and WebSocket
- Both Claude and Codex connectors emit typed `ConversationRowEntry` payloads
- All 306 tests pass, clippy clean

## Non-Negotiables

- Delete and replace. Do not preserve `tool_display.rs` as the core abstraction.
- The server owns semantics.
- No provider-specific string guessing outside provider normalization.
- No dual architecture. No fallback contract carried alongside the new one.
- Tests verify deterministic transforms and transport outcomes, not helper wiring.
- Prefer pure transforms, explicit payloads, and small module seams.
- If a gap exists in the contract, fix the contract first.

## Desired End State

```text
Claude SDK / Codex runtime payloads
  -> provider normalization
  -> normalized domain events
  -> API conversation contracts
  -> grouping
  -> HTTP + WebSocket transport
```

The critical design rule is:

- providers emit raw payloads
- OrbitDock server normalizes meaning
- transport exposes typed meaning

## Rust Type Tree

### Module Layout

```text
orbitdock-server/crates/protocol/src/
  lib.rs
  client.rs
  server.rs
  types.rs
  provider_normalization/
    mod.rs
    claude.rs
    codex.rs
    shared.rs
  domain_events/
    mod.rs
    conversation.rs
    tooling.rs
    approvals.rs
    workers.rs
    lifecycle.rs
  conversation_contracts/
    mod.rs
    rows.rs
    tool_payloads.rs
    activity_groups.rs
    approvals.rs
    workers.rs
    render_hints.rs
  grouping/
    mod.rs
    planner.rs
    grouping_keys.rs
    summaries.rs
```

### Layer 1: Provider Normalization

This layer consumes raw provider payloads and produces provider-agnostic normalized events.

Key types:

```rust
pub enum ProviderKind {
    Claude,
    Codex,
}

pub struct ProviderEventEnvelope {
    pub provider: ProviderKind,
    pub session_id: String,
    pub turn_id: Option<String>,
    pub timestamp: Option<String>,
    pub event: NormalizedProviderEvent,
}

pub enum NormalizedProviderEvent {
    AssistantContent(NormalizedAssistantContent),
    ToolInvocation(NormalizedToolInvocation),
    ToolResult(NormalizedToolResult),
    WorkerLifecycle(NormalizedWorkerLifecycle),
    ApprovalRequest(NormalizedApprovalRequest),
    Question(NormalizedQuestion),
    Hook(NormalizedHookEvent),
    Handoff(NormalizedHandoff),
    Plan(NormalizedPlanEvent),
    Reasoning(NormalizedReasoningEvent),
    Context(NormalizedContextEvent),
    System(NormalizedSystemEvent),
}
```

Rules:

- no transport strings beyond provider-native raw values
- no grouping
- pure transforms only

### Layer 2: Normalized Domain Events

This is OrbitDock's internal event language.

Key types:

```rust
pub enum ConversationEvent {
    UserMessage(UserMessageEvent),
    AssistantMessage(AssistantMessageEvent),
    Thinking(ThinkingEvent),
    Tool(ToolEvent),
    Approval(ApprovalEvent),
    Question(QuestionEvent),
    Worker(WorkerEvent),
    Hook(HookEvent),
    Handoff(HandoffEvent),
    Context(ContextEvent),
    System(SystemEvent),
}

pub struct ToolEvent {
    pub id: String,
    pub provider: ProviderKind,
    pub family: ToolFamily,
    pub kind: ToolKind,
    pub status: ToolStatus,
    pub turn_id: Option<String>,
    pub worker_id: Option<String>,
    pub grouping_key: Option<String>,
    pub invocation: ToolInvocationPayload,
    pub result: Option<ToolResultPayload>,
    pub started_at: Option<String>,
    pub ended_at: Option<String>,
    pub duration_ms: Option<u64>,
}
```

Core enums:

```rust
pub enum ToolFamily {
    Shell,
    FileRead,
    FileChange,
    Search,
    Web,
    Agent,
    Question,
    Approval,
    PermissionRequest,
    Plan,
    Mcp,
    Hook,
    Handoff,
    Context,
    Generic,
}

pub enum ToolStatus {
    Pending,
    Running,
    Completed,
    Failed,
    Cancelled,
    Blocked,
    NeedsInput,
}
```

`ToolKind` should be a fine-grained provider-neutral leaf enum. Examples:

- `Bash`
- `Edit`
- `Read`
- `Write`
- `Glob`
- `Grep`
- `WebSearch`
- `WebFetch`
- `McpToolCall`
- `SpawnAgent`
- `SendAgentInput`
- `ResumeAgent`
- `WaitAgent`
- `CloseAgent`
- `AskUserQuestion`
- `EnterPlanMode`
- `ExitPlanMode`
- `TodoWrite`
- `HookNotification`
- `HandoffRequested`

### Layer 3: API Conversation Contracts

This is the contract every consumer should receive.

Top-level row union:

```rust
pub enum ConversationRow {
    User(UserRow),
    Assistant(AssistantRow),
    Thinking(ThinkingRow),
    Tool(ToolRow),
    ActivityGroup(ActivityGroupRow),
    Question(QuestionRow),
    Approval(ApprovalRow),
    Worker(WorkerRow),
    Hook(HookRow),
    Handoff(HandoffRow),
    System(SystemRow),
}
```

Key structs:

```rust
pub struct ToolRow {
    pub id: String,
    pub provider: ProviderKind,
    pub family: ToolFamily,
    pub kind: ToolKind,
    pub status: ToolStatus,
    pub title: String,
    pub subtitle: Option<String>,
    pub summary: Option<String>,
    pub preview: Option<ToolPreview>,
    pub started_at: Option<String>,
    pub ended_at: Option<String>,
    pub duration_ms: Option<u64>,
    pub grouping_key: Option<String>,
    pub invocation: ToolInvocationPayload,
    pub result: Option<ToolResultPayload>,
    pub render_hints: RenderHints,
}

pub struct ActivityGroupRow {
    pub id: String,
    pub group_kind: ActivityGroupKind,
    pub title: String,
    pub subtitle: Option<String>,
    pub summary: Option<String>,
    pub child_count: usize,
    pub children: Vec<ToolRow>,
    pub turn_id: Option<String>,
    pub grouping_key: Option<String>,
    pub status: ToolStatus,
    pub render_hints: RenderHints,
}
```

The payload union must be explicit:

```rust
pub enum ToolInvocationPayload {
    Shell(ShellInvocationPayload),
    FileRead(FileReadInvocationPayload),
    FileChange(FileChangeInvocationPayload),
    Search(SearchInvocationPayload),
    Web(WebInvocationPayload),
    Agent(AgentInvocationPayload),
    Question(QuestionInvocationPayload),
    Approval(ApprovalInvocationPayload),
    PermissionRequest(PermissionRequestInvocationPayload),
    Plan(PlanInvocationPayload),
    Mcp(McpInvocationPayload),
    Hook(HookInvocationPayload),
    Handoff(HandoffInvocationPayload),
    Context(ContextInvocationPayload),
    Generic(GenericInvocationPayload),
}

pub enum ToolResultPayload {
    Shell(ShellResultPayload),
    FileRead(FileReadResultPayload),
    FileChange(FileChangeResultPayload),
    Search(SearchResultPayload),
    Web(WebResultPayload),
    Agent(AgentResultPayload),
    Question(QuestionResultPayload),
    Approval(ApprovalResultPayload),
    PermissionRequest(PermissionRequestResultPayload),
    Plan(PlanResultPayload),
    Mcp(McpResultPayload),
    Hook(HookResultPayload),
    Handoff(HandoffResultPayload),
    Context(ContextResultPayload),
    Generic(GenericResultPayload),
}
```

### Layer 4: Grouping

Grouping remains server-owned and deterministic.

Rules:

- group only contiguous compatible tool rows
- group only within one turn/activity block
- carry full child rows so grouped payloads stay inspectable
- no provider-specific grouping heuristics outside normalized events

### Layer 5: Transport

The same contract must appear in:

- HTTP bootstrap/read responses
- WebSocket live events and patches

There must be no hidden extra fields available on only one transport.

## Execution Phases

### Phase 0: Freeze boundaries

- [x] settle module families
- [x] settle top-level enums and unions
- [x] commit to delete-and-replace

### Phase 1: Provider normalization

- [ ] Claude normalization complete
- [ ] Codex normalization complete
- [ ] shared ids, timestamps, statuses, payload helpers complete

### Phase 2: Domain events

- [ ] map provider events into shared domain events
- [ ] remove provider branching from downstream shaping

### Phase 3: Conversation contracts

- [ ] implement `ConversationRow`
- [ ] implement typed invocation/result unions
- [ ] implement worker/question/approval/hook/handoff row contracts

### Phase 4: Grouping

- [ ] grouping keys finalized
- [ ] grouping summaries finalized
- [ ] deterministic planner implemented

### Phase 5: Transport cutover

- [ ] HTTP emits typed contracts
- [ ] WebSocket emits typed contracts
- [ ] bootstrap and live updates share schema and semantics

### Phase 6: Delete legacy path

- [ ] remove `tool_display.rs` from the live path
- [ ] delete old transport fields that duplicate or flatten typed contracts
- [ ] delete fallback helpers that recover meaning after flattening

### Phase 7: Verification

- [ ] provider normalization tests green
- [ ] domain event tests green
- [ ] grouping tests green
- [ ] HTTP contract tests green
- [ ] WebSocket contract tests green
- [ ] migration tests prove no transport regressions for supported consumers

## Parallel Worker Split

1. Contract freeze worker
   - core enums, ids, status/payload skeletons
2. Claude normalization worker
   - every Claude tool/event family
3. Codex normalization worker
   - every Codex tool/event family
4. Shared normalization worker
   - shared ids, timestamps, raw-to-normalized helpers
5. Domain event worker
   - provider-neutral event language
6. Conversation contract worker
   - row unions and payload unions
7. Grouping worker
   - keys, summaries, planner
8. HTTP transport worker
   - bootstrap/read path cutover
9. WebSocket transport worker
   - live/update path cutover
10. Legacy deletion worker
   - remove `tool_display.rs` and old flattened fields
11. Verification worker
   - pure normalization, contract, and transport tests

## Testing Strategy

Follow `testing-philosophy`.

Test outcomes:

- Claude raw payload -> normalized event
- Codex raw payload -> normalized event
- normalized event -> domain event
- domain event -> typed conversation contract
- grouping is deterministic and stable
- HTTP and WebSocket expose the same semantic row/payload shape
- adding a new provider payload requires inventory + normalization updates before transport changes
