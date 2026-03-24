# Rust Server Design Smells

Use this checklist when a patch looks easy but feels wrong.

## Smell: Same shape, different meaning

Example:

- `User(MessageRowContent)` also represents steer prompts because the payloads look alike

Why it is dangerous:

- existing match arms still compile
- old helper logic silently broadens in meaning
- reviewers see "small" diffs while invariants move underneath them

Refactor toward:

- dedicated enum variants
- dedicated structs
- explicit conversion at the boundary if two sources normalize into one internal type later

## Smell: A helper exists only to repair weak typing

Example:

- `is_real_user_prompt(row)` exists because `ConversationRow::User` is no longer actually "user"

Why it is dangerous:

- every callsite must remember the exception
- one missed helper call recreates the bug
- the compiler cannot enforce the rule

Refactor toward:

- move the distinction into the type system
- make the illegal path impossible or awkward to express

## Smell: Important behavior is inferred from transcript history

Example:

- determining queue state, approval truth, or session capabilities by scanning rows

Why it is dangerous:

- duplicated logic across server and client
- restore and live behavior diverge
- "current state" becomes a best-effort guess

Refactor toward:

- durable server-owned fields
- explicit aggregates in session state
- broadcasted deltas sourced from one authority

## Smell: Multiple layers can mutate the same business truth

Example:

- runtime mutates a value, persistence writes a variant of it directly, and transport derives a fallback

Why it is dangerous:

- race conditions
- restore bugs
- inconsistent reads depending on which path executed

Refactor toward:

- one write path
- one transition owner
- transport as mapping, not business logic

## Smell: Raw strings or ad-hoc JSON decide behavior

Example:

- branching on provider event names, message kinds, or status strings across many files

Why it is dangerous:

- typos become behavior
- exhaustiveness disappears
- refactors turn into global grep exercises

Refactor toward:

- enums
- typed deserialization at the boundary
- normalization near ingress, not deep in the core

## Smell: A bool is carrying a state machine

Example:

- `is_running`, `is_waiting`, `is_streaming`, `is_retryable` combinations that imply hidden modes

Why it is dangerous:

- illegal combinations are representable
- transition rules are unclear
- tests miss edge states

Refactor toward:

- an enum for mode
- a reducer or transition function for legal moves

## Smell: Tests need sleeps, polling, or heavy mocking

Why it is dangerous:

- the design does not expose a stable signal for completion
- behavior is coupled to timing instead of state
- mocks hide the integration seams that actually break

Refactor toward:

- pure transition functions
- event subscription or explicit state observation
- integration tests with real persistence and transport boundaries where it matters

## Smell: The "fix" adds a new exception path

Example:

- "do X for all user rows, except this one weird kind"

Why it is dangerous:

- exceptions accumulate faster than shared understanding
- future contributors copy the old pattern
- the codebase becomes grep-driven folklore

Refactor toward:

- narrower concepts
- smaller, sharper types
- match arms whose names already explain the rule
