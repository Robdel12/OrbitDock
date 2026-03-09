# Client Networking Rewrite Phase 1

Phase 1 hardens the server contract so the new client can be simple.

This phase is not a client refactor. It is a server/API/WebSocket contract pass. The output of this phase is a transport contract that later client phases can trust without reverse-engineering behavior from implementation details.

This document is the source of truth for Phase 1.

Companion structural plan:

- `plans/client-networking-state-phase-1-server-decomposition.md`

---

## Phase 1 Objective

Make every relevant server mutation and server-pushed update explicit enough that the new client can:

- apply REST responses immediately when appropriate
- rely on WS for eventual replicated updates when appropriate
- reject stale events deterministically
- avoid manual refreshes after mutations
- avoid transport-specific special casing in feature code

---

## Phase 1 Rules

- Do not preserve ambiguous endpoint behavior just because the current client depends on it.
- Do not add compatibility events purely for the old client shape.
- Do not make the client infer whether a REST response is authoritative.
- Do not make the client infer whether a WS event supersedes a REST response.
- Do not ship mutation endpoints that change shared state without either:
  - returning the updated state slice, or
  - broadcasting an authoritative replicated event
- Do not leave contract-critical server logic buried in giant multi-domain files when the phase is explicitly rewriting those contracts.

---

## Domains in Scope

Phase 1 covers these domains first:

- sessions index and session lifecycle summaries
- approvals
- review comments
- worktrees
- server info / cross-client primary state

Conversation streaming remains event-driven, but its revision contract is also defined here because later client phases depend on it.

---

## Contract Model

Every endpoint must fit one of these patterns.

### 1. Hydrate

REST returns authoritative state for the requested resource.

The initiating client updates from the response.

Examples:

- list sessions
- fetch session snapshot
- fetch conversation bootstrap/history
- list approvals
- list review comments
- list worktrees

### 2. Response Authoritative + Replicated

REST returns the authoritative updated entity or state slice for the initiating client.

WS broadcasts the same change for other connected clients.

Examples:

- create/update/delete review comment
- create/remove worktree
- create/resume/fork/takeover session
- rename/update session config
- mark session read
- set server role
- set client primary claim

### 3. Accepted + Eventual WS

REST only acknowledges that async work started.

The initiating client and all other clients update from WS.

Examples:

- send message
- steer turn
- interrupt
- compact
- undo
- rollback
- execute shell

---

## Revision Model

Phase 1 adds revision/version fields where ordering matters.

Phase 1 also restructures the server so those contracts live in obvious domain modules instead of `http_api.rs` and `persistence.rs` monoliths.

## Required Fields

- `sessions_revision`
  - monotonically increasing revision for the endpoint session index

- `session_revision`
  - monotonically increasing revision for summary/detail state of one session

- `conversation_revision`
  - monotonically increasing revision for conversation events within one session

- `review_revision`
  - monotonically increasing revision for a session's review comments

- `worktree_revision`
  - monotonically increasing revision for a repo root's worktree set

- `account_revision`
  - monotonically increasing revision for account/auth state

- `approval_version`
  - already exists and remains the approval ordering gate

## Rules

- Revisions are monotonic per scope, not globally across all scopes.
- WS events that update a scoped domain must include that domain's revision.
- Hydrate responses for that domain must include the current revision.
- The client must be able to reject stale replicated events using only the payload it receives.

---

## Sessions Contract

## Current Problem

Session lifecycle endpoints currently return useful data, but the surrounding replication semantics are inconsistent and not formally defined. The new client needs explicit session-index and per-session revision behavior.

## Required REST Shapes

### `GET /api/sessions`

Return:

```json
{
  "sessions_revision": 42,
  "sessions": [ ...SessionSummary... ]
}
```

### `GET /api/sessions/{id}`

Return:

```json
{
  "session_revision": 18,
  "session": { ...SessionState... }
}
```

### `POST /api/sessions`

Return:

```json
{
  "sessions_revision": 43,
  "session_id": "abc",
  "session": { ...SessionSummary... }
}
```

Behavior:

- initiating client applies returned summary immediately
- WS broadcasts a replicated session-index event for other clients

### `POST /api/sessions/{id}/resume`

Return:

```json
{
  "sessions_revision": 44,
  "session_id": "abc",
  "session": { ...SessionSummary... }
}
```

### `POST /api/sessions/{id}/takeover`

Return:

```json
{
  "sessions_revision": 45,
  "session_id": "abc",
  "session": { ...SessionSummary... },
  "accepted": true
}
```

This is intentionally different from the current response. The new client should not need to wait for an unrelated WS update to know the new session summary.

### `PATCH /api/sessions/{id}/name`

Return:

```json
{
  "sessions_revision": 46,
  "session_revision": 19,
  "session": { ...SessionSummary... }
}
```

### `PATCH /api/sessions/{id}/config`

Return:

```json
{
  "sessions_revision": 47,
  "session_revision": 20,
  "session": { ...SessionSummary... }
}
```

### `POST /api/sessions/{id}/fork`

Return:

```json
{
  "sessions_revision": 48,
  "source_session_id": "source",
  "new_session_id": "new",
  "session": { ...SessionSummary... }
}
```

### `POST /api/sessions/{id}/fork-to-worktree`

Return:

```json
{
  "sessions_revision": 49,
  "worktree_revision": 12,
  "source_session_id": "source",
  "new_session_id": "new",
  "session": { ...SessionSummary... },
  "worktree": { ...WorktreeSummary... }
}
```

### `POST /api/sessions/{id}/fork-to-existing-worktree`

Return:

```json
{
  "sessions_revision": 50,
  "source_session_id": "source",
  "new_session_id": "new",
  "session": { ...SessionSummary... }
}
```

### `POST /api/sessions/{id}/end`

Return:

```json
{
  "sessions_revision": 51,
  "session_id": "abc",
  "ended": true
}
```

The client does not need a huge payload here, but it does need the index revision.

## Required WS Shapes

Replace index-level ambiguity with a consistent upsert/remove model.

- `session_upserted`
  - includes `sessions_revision`
  - includes authoritative `session` summary

- `session_removed`
  - includes `sessions_revision`
  - includes `session_id`
  - used only when a session should disappear from the index entirely

- `session_state_changed`
  - includes `session_revision`
  - includes `session_id`
  - includes `changes`

`session_created` should be renamed or replaced by `session_upserted`. The client should not need to care whether the row was newly created or updated.

---

## Approval Contract

## Current Problem

Approvals are the best versioned domain today, but REST responses still under-specify the initiating-client contract. The new client should apply approval decision responses immediately and then reconcile replicated state safely.

## Required REST Shapes

### `GET /api/approvals`

Return:

```json
{
  "session_id": "abc",
  "approval_version": 7,
  "approvals": [ ...ApprovalHistoryItem... ]
}
```

If `session_id` is omitted for a global list, `approval_version` may also be omitted.

### `POST /api/sessions/{id}/approve`

Return:

```json
{
  "session_id": "abc",
  "request_id": "req-1",
  "outcome": "applied",
  "active_request_id": "req-2",
  "approval_version": 8
}
```

### `POST /api/sessions/{id}/answer`

Return:

```json
{
  "session_id": "abc",
  "request_id": "req-1",
  "outcome": "applied",
  "active_request_id": null,
  "approval_version": 9
}
```

### `DELETE /api/approvals/{id}`

Return:

```json
{
  "approval_id": 123,
  "deleted": true
}
```

If this is visible to other clients, it must also replicate via WS.

### `POST /api/sessions/{id}/mark-read`

Return:

```json
{
  "sessions_revision": 52,
  "session_revision": 21,
  "session_id": "abc",
  "unread_count": 0
}
```

## Required WS Shapes

- `approval_state_changed`
  - includes `session_id`
  - includes `approval_version`
  - includes authoritative pending approval state

- `approval_history_deleted`
  - includes `approval_id`

- `session_state_changed`
  - may still carry unread-count deltas, but must include `session_revision`

### Locked Rule

The client should never have to infer pending-approval state by mixing:

- `approval_requested`
- `approval_decision_result`
- `session_delta`

into one guessy state machine.

Either unify these semantics into one approval-state event, or define exact ordering guarantees. Phase 1 prefers the unified event.

---

## Review Comment Contract

## Current Problem

Create broadcasts today, but update/delete do not reliably behave as response-authoritative plus replicated operations. This is exactly the kind of gap that created stale UI in the first place.

## Required REST Shapes

### `GET /api/sessions/{id}/review-comments`

Return:

```json
{
  "session_id": "abc",
  "review_revision": 11,
  "comments": [ ...ReviewComment... ]
}
```

### `POST /api/sessions/{id}/review-comments`

Return:

```json
{
  "session_id": "abc",
  "review_revision": 12,
  "comment": { ...ReviewComment... }
}
```

### `PATCH /api/review-comments/{id}`

Return:

```json
{
  "session_id": "abc",
  "review_revision": 13,
  "comment": { ...ReviewComment... }
}
```

### `DELETE /api/review-comments/{id}`

Return:

```json
{
  "session_id": "abc",
  "review_revision": 14,
  "comment_id": "rc-123",
  "deleted": true
}
```

## Required WS Shapes

- `review_comment_created`
  - includes `session_id`
  - includes `review_revision`
  - includes `comment`

- `review_comment_updated`
  - includes `session_id`
  - includes `review_revision`
  - includes `comment`

- `review_comment_deleted`
  - includes `session_id`
  - includes `review_revision`
  - includes `comment_id`

- `review_comments_replaced`
  - optional hydrate-style broadcast if ever needed

### Locked Rule

Review comment update/delete are not allowed to be silent shared-state mutations anymore.

---

## Worktree Contract

## Current Problem

Worktree behavior is currently split between:

- query-like list/discover endpoints
- mutation endpoints that sometimes return useful state
- replication that is not consistently guaranteed

The new client needs repo-scoped worktree authority with revision gates.

## Required REST Shapes

### `GET /api/worktrees?repo_root=...`

Return:

```json
{
  "repo_root": "/repo",
  "worktree_revision": 3,
  "worktrees": [ ...WorktreeSummary... ]
}
```

### `POST /api/worktrees/discover`

Return:

```json
{
  "repo_root": "/repo",
  "worktree_revision": 4,
  "worktrees": [ ...WorktreeSummary... ]
}
```

This endpoint is classified as hydrate. The client should replace the repo-scoped worktree list with the response.

### `POST /api/worktrees`

Return:

```json
{
  "repo_root": "/repo",
  "worktree_revision": 5,
  "worktree": { ...WorktreeSummary... }
}
```

### `DELETE /api/worktrees/{id}`

Return:

```json
{
  "repo_root": "/repo",
  "worktree_revision": 6,
  "worktree_id": "wt-123",
  "deleted": true
}
```

## Required WS Shapes

- `worktrees_replaced`
  - includes `repo_root`
  - includes `worktree_revision`
  - includes full `worktrees`

- `worktree_created`
  - includes `repo_root`
  - includes `worktree_revision`
  - includes `worktree`

- `worktree_updated`
  - includes `repo_root`
  - includes `worktree_revision`
  - includes `worktree`

- `worktree_removed`
  - includes `repo_root`
  - includes `worktree_revision`
  - includes `worktree_id`

### Locked Rule

Repo-scoped worktree state is reconciled by `repo_root` plus `worktree_revision`. Request IDs are not a source of truth.

---

## Server Info and Primary-State Contract

## Required REST Shapes

### `POST /api/server/role`

Return:

```json
{
  "account_revision": 2,
  "is_primary": true
}
```

### `POST /api/server/client-primary-claim`

Return:

```json
{
  "account_revision": 3,
  "accepted": true
}
```

## Required WS Shapes

- `server_info_updated`
  - includes `account_revision`
  - includes authoritative server-info payload

The new client should not special-case this as some odd list-side-band event. It is a normal replicated domain update.

---

## Conversation Revision Contract

Conversation remains WS-authoritative for live turn updates, but it still needs a formal revision rule.

## Required REST Shapes

### `GET /api/sessions/{id}`

`session` should carry `conversation_revision` when a full session snapshot includes conversation payload.

### `GET /api/sessions/{id}/conversation`

Return:

```json
{
  "conversation_revision": 101,
  "session": { ...SessionState... },
  "total_message_count": 123,
  "has_more_before": true,
  "oldest_sequence": 77,
  "newest_sequence": 123
}
```

### `GET /api/sessions/{id}/messages`

Return:

```json
{
  "session_id": "abc",
  "conversation_revision": 101,
  "messages": [ ...Message... ],
  "total_message_count": 123,
  "has_more_before": true,
  "oldest_sequence": 55,
  "newest_sequence": 76
}
```

## Required WS Shapes

- `conversation_snapshot_replaced`
  - includes `session_id`
  - includes `conversation_revision`
  - includes snapshot payload

- `conversation_message_appended`
  - includes `session_id`
  - includes `conversation_revision`
  - includes message

- `conversation_message_updated`
  - includes `session_id`
  - includes `conversation_revision`
  - includes message id and changes

### Locked Rule

The client must be able to rebuild a session's conversation state after reconnect using:

- hydrate response
- revision-aware replay
- stale-event rejection

without bespoke heuristics.

---

## Current Endpoint Changes Required in Existing Code

These are the most obvious Phase 1 fixes relative to current code.

- `PATCH /api/review-comments/{id}`
  - currently returns only `{comment_id, ok}`
  - must return updated comment plus `session_id` and `review_revision`
  - must broadcast `review_comment_updated`

- `DELETE /api/review-comments/{id}`
  - currently returns only `{comment_id, ok}`
  - must return `session_id`, `comment_id`, `deleted`, and `review_revision`
  - must broadcast `review_comment_deleted`

- `POST /api/worktrees`
  - currently returns only `worktree`
  - must include `repo_root` and `worktree_revision`
  - must broadcast `worktree_created`

- `DELETE /api/worktrees/{id}`
  - currently returns only `worktree_id` and `ok`
  - must include `repo_root`, `worktree_revision`, and `deleted`

- session mutation endpoints
  - must include `sessions_revision`
  - must behave as response-authoritative for initiating clients

- hydrate endpoints
  - must include domain revision fields

---

## Testing Strategy for Phase 1

Follow the `testing-philosophy` skill explicitly.

That means for this phase:

- test the contract users and clients rely on, not internal handler structure
- minimize mocking to transport/external boundaries only
- prefer integration tests over over-mocked unit tests for endpoint behavior
- wait on concrete responses and concrete replicated events, not sleeps

### Unit

Use unit tests only for pure helpers added during Phase 1, such as:

- revision comparison helpers
- response/event mapping helpers

### Integration

Primary test level for this phase.

Test outcomes like:

- "review comment update returns the updated comment and subscribed clients receive `review_comment_updated`"
- "create worktree returns a worktree with repo-scoped revision and subscribed clients receive `worktree_created`"
- "mark read returns unread count zero and subscribed clients observe the same unread state"
- "create session returns authoritative summary and list subscribers receive the upsert"

### Anti-Patterns

Do not add tests like:

- "handler X calls broadcast method Y"
- "persist command Z was sent before helper A"

Those are implementation details.

---

## Phase 1 Checklist

- [ ] add revision fields for sessions, session state, conversation, review, worktrees, and account/server-info domains
- [ ] make review comment update/delete response-authoritative and replicated
- [ ] make worktree create/remove response-authoritative and replicated
- [ ] make discover worktrees a hydrate endpoint with repo-scoped revision
- [ ] make session mutation endpoints response-authoritative for initiating clients
- [ ] normalize index-level WS events to upsert/remove semantics
- [ ] define or replace approval WS semantics so the client does not need to infer state from overlapping events
- [ ] add integration tests for each changed contract

Phase 1 is complete when the new contract is true in code, not just described here.
