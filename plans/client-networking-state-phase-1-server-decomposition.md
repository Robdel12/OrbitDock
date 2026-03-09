# Client Networking Rewrite Phase 1B

Phase 1B makes the server code match the architecture we are trying to ship.

This is not optional cleanup. The new client architecture depends on a server that is easy to reason about by domain. If the API, persistence, and websocket layers stay monolithic, we will keep reintroducing ambiguous behavior because the code is too hard to hold in one head.

This document is the source of truth for the server decomposition work inside Phase 1.

---

## Why This Is In Scope

Current server file sizes are already architectural debt:

- `http_api.rs`: 5,408 lines
- `persistence.rs`: 6,855 lines
- `websocket.rs`: 2,281 lines
- `main.rs` owns a giant inline router table

That makes the contract rewrite harder to verify, harder to test, and easier to regress. A clean client rewrite built on top of that would still be standing on unstable foundations.

---

## Objective

Split the server into domain-oriented modules so that:

- each API domain has one obvious home
- route wiring is readable
- persistence logic is grouped by domain
- websocket transport is separate from domain behavior
- future Phase 2+ client work can change one server domain without spelunking giant files

This phase is complete when the server structure itself reflects the architecture.

---

## Non-Negotiable Rules

- Do not create "misc" or "helpers" dumping grounds.
- Do not move code by arbitrary line ranges. Move it by domain ownership.
- Do not preserve giant facade files full of unrelated logic just because they already exist.
- Do not combine transport and domain behavior in the same module when a boundary is clear.
- Do not change behavior accidentally while moving code. Structural change should be verified by outcome tests.
- Follow `testing-philosophy`: test real request/response and event outcomes, not whether a function moved to a new file.

---

## Target Server Shape

## HTTP API

Replace one giant `http_api.rs` file with an `http_api/` module tree.

Target shape:

```text
orbitdock-server/crates/server/src/http_api/
  mod.rs
  router.rs
  shared.rs
  sessions.rs
  session_actions.rs
  session_lifecycle.rs
  approvals.rs
  review_comments.rs
  worktrees.rs
  server_info.rs
  models.rs
  codex_auth.rs
  files.rs
  shell.rs
```

Rules:

- `router.rs` owns route registration only.
- `shared.rs` owns shared response/error/request helpers used across domains.
- Domain files own only their own request/response types and handlers.
- `main.rs` should call one HTTP router builder instead of inlining the full route table.

## Persistence

Replace one giant `persistence.rs` file with a `persistence/` module tree.

Target shape:

```text
orbitdock-server/crates/server/src/persistence/
  mod.rs
  db.rs
  sessions.rs
  messages.rs
  approvals.rs
  review_comments.rs
  worktrees.rs
  config.rs
  subagents.rs
  usage.rs
```

Rules:

- `db.rs` owns connection setup and shared SQLite helpers.
- Domain modules own their own CRUD and row decoding.
- `mod.rs` can re-export stable entry points during the split, but it should stay thin.

## WebSocket

`ws_handlers/` already points in the right direction. Finish that direction instead of keeping a fat `websocket.rs`.

Target shape:

```text
orbitdock-server/crates/server/src/websocket/
  mod.rs
  transport.rs
  router.rs
  connection.rs
```

Existing domain behavior should continue to live under:

```text
orbitdock-server/crates/server/src/ws_handlers/
```

Rules:

- websocket transport concerns stay in `websocket/`
- domain message handling stays in `ws_handlers/`
- `websocket.rs` should become a thin facade or disappear entirely

---

## Recommended Migration Order

### Step 1

Extract HTTP router construction out of `main.rs`.

Goal:

- `main.rs` stops being the place where every endpoint is reasoned about
- route ownership becomes explicit before handler files are moved

### Step 2

Split `http_api.rs` by domain.

Recommended first cuts:

- `review_comments.rs`
- `worktrees.rs`
- `approvals.rs`
- `sessions.rs`
- `session_actions.rs`
- `session_lifecycle.rs`

These are already central to the networking rewrite and should become the clean examples for the rest of the tree.

### Step 3

Split `persistence.rs` along the same domain boundaries.

Recommended first cuts:

- `review_comments.rs`
- `worktrees.rs`
- `approvals.rs`
- `sessions.rs`

The point is to make it obvious which storage code backs which REST and WS contract.

### Step 4

Thin out websocket transport.

Move connection setup, framing, and route dispatch into `websocket/` modules. Keep domain handlers where they already belong in `ws_handlers/`.

### Step 5

Delete dead facades and duplicate exports.

By the end of this phase:

- giant compatibility files should be gone or reduced to a small re-export surface
- new code should land only in the new module homes

---

## Phase 1B Checklist

- [x] Extract HTTP router builder from `main.rs`
- [x] Create `http_api/` module tree
- [x] Move review comment handlers and types into `http_api/review_comments.rs`
- [x] Move worktree handlers and types into `http_api/worktrees.rs`
- [x] Move approval handlers and types into `http_api/approvals.rs`
- [x] Move session read/query handlers into `http_api/sessions.rs`
- [x] Move session interaction handlers into `http_api/session_actions.rs`
- [x] Move session lifecycle/detail handlers into `http_api/session_lifecycle.rs`
- [x] Create `persistence/` module tree
- [x] Move review comment persistence into `persistence/review_comments.rs`
- [x] Move worktree persistence into `persistence/worktrees.rs`
- [x] Move approval persistence into `persistence/approvals.rs`
- [x] Move server info handlers and types into `http_api/server_info.rs`
- [x] Move Codex auth handlers and types into `http_api/codex_auth.rs`
- [x] Move filesystem and subagent tooling handlers into `http_api/files.rs`
- [x] Move permission rules handlers and helpers into `http_api/permissions.rs`
- [x] Move transcript parsing and transcript-backed helpers into `persistence/transcripts.rs`
- [x] Move message paging and message-loading helpers into `persistence/messages.rs`
- [x] Move usage snapshot helpers into `persistence/usage.rs`
- [x] Move config and Claude model cache helpers into `persistence/config.rs`
- [x] Move subagent queries into `persistence/subagents.rs`
- [ ] Move session persistence into `persistence/sessions.rs`
- [x] Extract websocket transport and routing into `websocket/` modules
- [ ] Reduce `main.rs`, `http_api.rs`, `persistence.rs`, and `websocket.rs` to thin facades or delete them

### Progress Notes

- `main.rs` now merges a dedicated HTTP router instead of owning the full API route table.
- Review comment HTTP handlers now live in `http_api/review_comments.rs`.
- Worktree HTTP handlers now live in `http_api/worktrees.rs`.
- Approval HTTP handlers now live in `http_api/approvals.rs`.
- Session read/query handlers now live in `http_api/sessions.rs`.
- Session interaction handlers now live in `http_api/session_actions.rs`.
- Session lifecycle and ownership-transition handlers now live in `http_api/session_lifecycle.rs`.
- Server info handlers and control-plane state mutations now live in `http_api/server_info.rs`.
- Codex auth handlers now live in `http_api/codex_auth.rs`.
- Filesystem browsing, recent-project listing, git-init, and subagent tool handlers now live in `http_api/files.rs`.
- Permission rules handlers and settings-file helpers now live in `http_api/permissions.rs`.
- Approval persistence now lives in `persistence/approvals.rs`.
- Review comment persistence now lives in `persistence/review_comments.rs`.
- Worktree read helpers now live in `persistence/worktrees.rs`.
- Transcript parsing and transcript-backed recovery helpers now live in `persistence/transcripts.rs`.
- Message loading and paging helpers now live in `persistence/messages.rs`.
- Usage snapshot helpers now live in `persistence/usage.rs`.
- Config reads and Claude model cache helpers now live in `persistence/config.rs`.
- Subagent lookup helpers now live in `persistence/subagents.rs`.
- WebSocket routing now lives in `websocket/router.rs`.
- WebSocket outbound transport and replay/snapshot helpers now live in `websocket/transport.rs`.
- Server-info message construction now lives in `websocket/server_info.rs`.
- `http_api.rs` is down to 1,810 lines from the prior 5,408-line monolith and now mostly contains shared HTTP concerns plus the remaining unsplit domains.
- `persistence.rs` is down to 4,866 lines from the prior 6,855-line monolith and now delegates approvals, review comments, worktree helpers, transcript parsing, message paging, config/model cache reads, subagent queries, and usage helpers to domain modules.
- `websocket.rs` is down to 2,008 lines from the prior 2,281-line monolith and now delegates routing plus outbound transport helpers to `websocket/`.
- Outcome verification follows `testing-philosophy`: `make rust-check` and `make rust-test` pass after the extraction, including the existing HTTP outcome tests, transcript recovery tests, and WebSocket behavior tests.

---

## Testing

This phase follows `testing-philosophy`.

Test the public outcomes that matter while code moves:

- REST endpoints still return the same contract
- websocket events still emit the same payloads
- persistence-backed reads and writes still produce the same visible state

Prefer:

- integration tests at the handler boundary
- integration tests at the persistence boundary
- small unit tests only for pure helpers introduced during extraction

Do not add tests that only prove:

- a function lives in a different module
- a router calls a specific helper
- an internal helper was invoked

If structural moves make behavior harder to verify, improve the public tests rather than mocking internals.

---

## Exit Criteria

Phase 1B is complete when:

- server domains have obvious module homes
- route registration is readable at a glance
- `http_api.rs` is no longer a giant multi-domain file
- `persistence.rs` is no longer a giant multi-domain file
- websocket transport and websocket domain handling are clearly separated
- a developer can change review comments, worktrees, approvals, or sessions without searching unrelated parts of the server

---

## Handoff Notes

If you are picking up only this phase:

- do structural moves one domain at a time
- keep behavior stable while moving code
- run outcome-focused tests after each domain extraction
- do not let new endpoint work land back in the old monoliths

If you need to choose where to start, start with:

1. `http_api/review_comments.rs`
2. `http_api/worktrees.rs`
3. `persistence/review_comments.rs`
4. `persistence/worktrees.rs`

Those domains are already at the center of the networking rewrite and give the cleanest signal first.
