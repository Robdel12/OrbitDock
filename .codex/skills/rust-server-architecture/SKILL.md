---
name: rust-server-architecture
description: Use when writing, reviewing, or refactoring OrbitDock Rust server code to implement features and system designs without shortcuts. Covers strong domain modeling, typed boundaries, single-writer persistence, state transitions, additive migrations, connector/runtime separation, and when to pull in testing-philosophy for confidence.
---

# Rust Server Architecture

Use this skill when the work touches `orbitdock-server/` and the quality of the design matters as much as the patch itself.

The goal is not just "make the tests pass." The goal is to make the server own durable truth, make invalid states hard or impossible to represent, and let the compiler force correct updates when the model changes.

## Start Here

Before changing code, read only the docs that match the task:

- `docs/repo-workflow.md` for where the code belongs and which `make rust-*` commands to use
- `docs/engineering-guardrails.md` for server-authoritative rules and typed-boundary expectations
- `docs/database-and-persistence.md` when schema, restore, hydration, or conversation rows are involved

If tests are part of the task, also use `testing-philosophy`.

## Workflow

### 1. State the invariant first

Write down the user-facing or system-facing truth the server must protect.

Examples:

- "steer rows are not user prompts"
- "only the server owns durable approval state"
- "conversation rows get sequence numbers from one writer"

Do not start from the existing shape of the code if that shape is already suspicious.

### 2. Find the authority boundary

Decide which layer owns the truth:

- `domain/` for business rules and pure state transitions
- `runtime/` for orchestration, actors, registries, and command flow
- `transport/` for HTTP and WebSocket mapping
- `infrastructure/` for SQLite, filesystem, auth, crypto, and external concerns
- `connectors/` for provider-specific translation

If multiple layers can independently "decide" the same thing, the design is probably wrong.

### 3. Make invalid states unrepresentable

Prefer:

- enums over booleans when there are meaningful modes
- dedicated structs or enum variants over "same shape, different meaning"
- newtypes over raw `String` or `u64` when identity matters
- typed params structs over long positional argument lists

Do not reuse a variant just because the payload shape matches.

Bad:

```rust
enum ConversationRow {
    User(MessageRowContent),
}
```

with steer encoded somewhere else in the payload or inferred by helpers.

Better:

```rust
enum ConversationRow {
    User(UserPromptRow),
    Steer(SteerPromptRow),
}
```

If changing the meaning should force the compiler to revisit every match arm, it needs its own type.

### 4. Prefer explicit transitions over scattered conditionals

When behavior depends on state, centralize it in a transition function, reducer, or actor command path.

Prefer a small number of obvious transition points over many helper methods that each tweak one field.

If a fix requires "remember to call this helper everywhere," stop and redesign.

### 5. Keep persistence and protocol honest

When durable truth changes:

1. update the domain model
2. update persistence read/write paths
3. update restore and hydration logic
4. update protocol types if clients need the field
5. verify the client renders server truth instead of reconstructing it

Do not hide a missing persisted concept behind client inference or transcript scanning.

### 6. Preserve the single-writer path

For conversation rows and other sequence-owned state:

- do not create side-path writes
- do not persist before sequence assignment
- do not let helpers bypass the actor or transition layer

If the design seems to need a second writer, the design almost always needs to be reworked instead.

### 7. Design for tests, then write the right tests

Use `testing-philosophy`.

For Rust server work, the usual split is:

- unit tests for pure domain functions and state transitions
- integration tests for persistence, protocol mapping, and component boundaries
- workflow tests for user-visible behavior across runtime paths

Do not mock your own domain model to compensate for a tangled design. Untangle the design.

### 8. Let tooling push the design upward

- use `make rust-check` for fast compile feedback
- use `make rust-check-workspace` when shared crates or workspace wiring changed
- use `make rust-test` for behavior changes
- use `make rust-ci` when the change is broad or risky

Do not silence Clippy design feedback with `#[allow(clippy::...)]` unless explicitly approved.

## OrbitDock-Specific Non-Negotiables

- The Rust server owns durable state. The client should not derive business truth by replaying history.
- Keep REST for request/response mutations and reads. Use WebSocket for subscriptions, streaming, and broadcasts.
- Keep typed protocol boundaries. Do not replace real schemas with bags of fields.
- SQLite ownership stays in the Rust server.
- Conversation rows must stay on the single-writer persistence path.

## Smells That Mean “Refactor, Don’t Patch”

Read `references/design-smells.md` when the change feels deceptively small or "just one more helper" seems tempting.

Common smell:

- the old code keeps compiling after a semantic change because two concepts still share one variant or one payload type

That is not safety. That is hidden coupling.

## Review Standard

When reviewing or implementing, ask:

1. What invariant is the server protecting?
2. Which layer is authoritative for that invariant?
3. Could the compiler catch a mistaken callsite after this change?
4. Did we introduce a second source of truth?
5. Are tests proving user-visible outcomes and durable behavior?

If the answer to question 3 is "no" and the concept matters, the typing is probably still too weak.
