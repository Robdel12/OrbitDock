# Tool Payload API Reset Source Of Truth

Last updated: March 13, 2026

This is the active source of truth for the provider payload reset.

This plan is 100% API, protocol, and server work.

It exists to replace OrbitDock's flattened message/tool contract with a typed, provider-neutral contract that is authoritative over both HTTP and WebSocket.

This plan is driven by:

- `plans/provider-tool-inventory-source-of-truth.md`
- real provider source files, not docs
- `testing-philosophy`

## Status

- provider inventory is complete enough to start the reset
- Rust protocol scaffolding has started
- no downstream consumer work is in scope for this plan

## Non-Negotiables

- Delete and replace. Do not preserve `tool_display.rs` as the core abstraction.
- The server owns tool semantics.
- HTTP and WebSocket must expose the same semantic contract.
- No provider-specific guessing outside provider normalization.
- No dual architecture. No long-lived fallback path.
- Tests verify deterministic transforms and contract outcomes, not helper wiring.

## Problem Statement

Right now OrbitDock flattens provider payloads too early:

- provider payloads are messy and inconsistent
- the protocol collapses too much into generic `Message` fields
- `tool_display.rs` tries to recover meaning after flattening
- HTTP and WebSocket do not expose a strong typed tool/activity model

That leads to unstable downstream contracts and weak server-side semantics.

The fix is to move semantic ownership into the protocol/server layer.

## Target Architecture

```text
Provider runtime payload
  -> provider normalization
  -> normalized domain events
  -> semantic API conversation contracts
  -> HTTP + WebSocket transport
```

## Contract Layers

### Layer 1: Provider Normalization

Rust modules:

- `provider_normalization/claude.rs`
- `provider_normalization/codex.rs`
- `provider_normalization/shared.rs`

Input:

- raw Claude SDK events/messages/tool payloads
- raw Codex thread items/approval/question/progress payloads

Output:

- `ProviderEventEnvelope`
- `NormalizedProviderEvent`

Rules:

- no display heuristics
- no consumer-specific shaping
- pure transforms only

### Layer 2: Normalized Domain Events

Rust modules:

- `domain_events/conversation.rs`
- `domain_events/tooling.rs`
- `domain_events/approvals.rs`
- `domain_events/workers.rs`
- `domain_events/lifecycle.rs`

This is OrbitDock's internal event language.

Key outputs:

- `ToolEvent`
- `ApprovalEvent`
- `QuestionEvent`
- `WorkerEvent`
- `HookEvent`
- `HandoffEvent`
- `ContextEvent`
- `SystemEvent`

### Layer 3: API Conversation Contracts

Rust modules:

- `conversation_contracts/rows.rs`
- `conversation_contracts/tool_payloads.rs`
- `conversation_contracts/activity_groups.rs`
- `conversation_contracts/approvals.rs`
- `conversation_contracts/workers.rs`
- `conversation_contracts/render_hints.rs`

This is the transport contract exposed to every consumer.

Top-level row union:

- `ConversationRow::User`
- `ConversationRow::Assistant`
- `ConversationRow::Thinking`
- `ConversationRow::Tool`
- `ConversationRow::ActivityGroup`
- `ConversationRow::Question`
- `ConversationRow::Approval`
- `ConversationRow::Worker`
- `ConversationRow::Hook`
- `ConversationRow::Handoff`
- `ConversationRow::System`

### Layer 4: Grouping

Rust modules:

- `grouping/planner.rs`
- `grouping/grouping_keys.rs`
- `grouping/summaries.rs`

Rules:

- group only contiguous tool rows
- group only within a single turn/activity block
- preserve inspectability in verbose transport
- grouping must be deterministic and pure

## Tool Families

OrbitDock should normalize both providers into these families:

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

## Rust Module Reset

Delete the current central architecture:

- `orbitdock-server/crates/protocol/src/tool_display.rs`

Replace it with:

- `orbitdock-server/crates/protocol/src/provider_normalization/`
- `orbitdock-server/crates/protocol/src/domain_events/`
- `orbitdock-server/crates/protocol/src/conversation_contracts/`
- `orbitdock-server/crates/protocol/src/grouping/`

## Transport Requirements

The new typed contract must be available over both:

- HTTP bootstrap/read paths
- WebSocket live/update paths

The same row and payload unions must be used in both places.

No WebSocket-only or HTTP-only semantic variants.

## Phases

### Phase 0: Freeze contract boundaries

- [ ] finalize `ProviderEventEnvelope`
- [ ] finalize `NormalizedProviderEvent`
- [ ] finalize `ToolFamily`
- [ ] finalize `ToolKind`
- [ ] finalize `ToolStatus`

### Phase 1: Claude normalization

- [ ] normalize every Claude tool/event family from the SDK source
- [ ] cover invocation + result payloads
- [ ] cover question / approval / plan / worker / hook variants

### Phase 2: Codex normalization

- [ ] normalize every Codex thread item / tool / worker / handoff / approval variant
- [ ] cover invocation + result payloads
- [ ] cover lifecycle-only variants cleanly

### Phase 3: Domain events

- [ ] map both providers into shared domain events
- [ ] remove provider-specific branching from downstream protocol shaping

### Phase 4: API row contracts

- [ ] implement `ConversationRow`
- [ ] implement `ToolRow`
- [ ] implement `ActivityGroupRow`
- [ ] implement typed invocation/result unions

### Phase 5: Transport cutover

- [ ] HTTP conversation/session responses emit typed contracts
- [ ] WebSocket events emit typed contracts
- [ ] bootstrap and live updates share the same row schema

### Phase 6: Delete legacy path

- [ ] remove `tool_display.rs` from the live protocol path
- [ ] stop computing `Message.tool_display` as the primary contract
- [ ] remove legacy transport fields once no longer needed

### Phase 7: Verification

- [ ] provider normalization tests green
- [ ] domain event tests green
- [ ] HTTP contract tests green
- [ ] WebSocket contract tests green
- [ ] no provider-specific string guessing remains outside normalization

## Parallel Worker Split

1. Contract freeze worker
   - core enums, shared ids, shared payload skeletons
2. Claude normalization worker
   - all Claude tool/event families
3. Codex normalization worker
   - all Codex tool/event families
4. Domain event worker
   - provider-neutral event language
5. Conversation contract worker
   - row unions and payload unions
6. Grouping worker
   - deterministic grouping keys and summaries
7. HTTP transport worker
   - bootstrap/read path cutover
8. WebSocket transport worker
   - live/update path cutover
9. Legacy deletion worker
   - remove `tool_display.rs` consumers
10. Verification worker
   - pure normalization and contract tests

## Testing Strategy

Follow `testing-philosophy`.

Test outcomes:

- Claude raw payload -> normalized event
- Codex raw payload -> normalized event
- normalized event -> domain event
- domain event -> typed row contract
- typed row contract appears identically in HTTP and WebSocket
- grouping is deterministic and stable
- provider additions require inventory + normalization updates before transport changes
