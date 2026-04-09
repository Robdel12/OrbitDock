# Server Functional Refactor Decomposition

Date: 2026-04-09

## Context

- The `orbitdock-server` crate has several large files that are carrying multiple architectural roles at once.
- The biggest hotspots are concentrated in `runtime/`, `transport/http/`, `infrastructure/persistence/`, and the sessions domain.
- The refactor needs to preserve the existing server-authoritative state model from [docs/ARCHITECTURE.md](/Users/robertdeluca/Developer/OrbitDock/docs/ARCHITECTURE.md).
- Functional, pure, and immutable design should be a first-class constraint, not just a cleanup preference.

## Why This Change

- Large files are currently blending business rules, orchestration, transport mapping, persistence wiring, and external side effects.
- That makes it too easy for business logic to drift out of the transition path and into helpers, handlers, or runtime coordinators.
- The server already has the right core invariant: validate -> persist -> broadcast through `ProcessEvent` and the pure transition function.
- The refactor should make that invariant easier to preserve by making authority boundaries obvious in the file layout.

## Design Rules

### Functional Core, Mutable Shell

- Keep `domain/` as the functional core: pure transforms, typed state, explicit transitions, no IO.
- Keep `runtime/` as the mutable shell: actor coordination, command flow, effect execution, caching, broadcast plumbing.
- Keep `transport/` as mapping only: request parsing, response shaping, status-code mapping, no business truth.
- Keep `infrastructure/` as the side-effect boundary: SQLite, filesystem, auth, crypto, external processes.
- Keep `connectors/` as translation layers from provider payloads into typed server inputs.

### Immutability Rules

- Prefer immutable state structs and pure replacement over helper methods that mutate unrelated fields.
- Treat `SessionHandle` as an actor-owned projection/cache, not the home of business logic.
- Make invalid states harder to represent with enums, typed structs, and narrower APIs.
- Keep conversation rows and approvals on the existing single-writer path.

### Mutation Rules

- Default all durable state changes to `SessionCommand::ProcessEvent`.
- Do not introduce new `ApplyDelta { persist_op: None }` sites beyond the already-documented exceptions.
- Do not split persist and broadcast responsibilities across different layers.
- Do not let connectors, HTTP handlers, or registry helpers decide business truth independently.

## Current Hot Spots

- `orbitdock-server/crates/server/src/domain/sessions/session.rs` — 3051 LOC
- `orbitdock-server/crates/server/src/transport/http/mission_control.rs` — 2241 LOC
- `orbitdock-server/crates/server/src/infrastructure/persistence/mod.rs` — 2050 LOC
- `orbitdock-server/crates/server/src/connectors/claude_hooks/handler.rs` — 1815 LOC
- `orbitdock-server/crates/server/src/runtime/codex_config.rs` — 1485 LOC
- `orbitdock-server/crates/server/src/domain/mission_control/config.rs` — 1483 LOC
- `orbitdock-server/crates/server/src/runtime/session_mutations.rs` — 1457 LOC
- `orbitdock-server/crates/server/src/infrastructure/persistence/session_reads.rs` — 1421 LOC
- `orbitdock-server/crates/server/src/runtime/session_registry.rs` — 1420 LOC
- `orbitdock-server/crates/server/src/transport/http/session_lifecycle/` — split across endpoint-family modules

## Target Design

### 1. Sessions Core

Current hotspot:

- `orbitdock-server/crates/server/src/domain/sessions/session.rs`

Target modules:

- `orbitdock-server/crates/server/src/domain/sessions/state.rs`
  - Immutable session aggregate state.
- `orbitdock-server/crates/server/src/domain/sessions/conversation_state.rs`
  - Pure row sequencing, retention, unread counts, paging.
- `orbitdock-server/crates/server/src/domain/sessions/approval_state.rs`
  - Pure pending-approval queue behavior.
- `orbitdock-server/crates/server/src/domain/sessions/snapshot.rs`
  - Pure mapping from domain state to `SessionSnapshot`.
- `orbitdock-server/crates/server/src/domain/sessions/restore.rs`
  - Pure mapping from restored persistence data into domain state.
- `orbitdock-server/crates/server/src/runtime/session_handle.rs`
  - Actor-owned mutable shell, ArcSwap refresh, broadcast wiring.

Design intent:

- Move business rules and state-shaping out of `SessionHandle`.
- Keep the actor shell thin and imperative.
- Make conversation, approvals, and snapshot projection independently testable as pure modules.

### 2. Runtime Orchestration

Current hot spots:

- `orbitdock-server/crates/server/src/runtime/session_mutations.rs`
- `orbitdock-server/crates/server/src/runtime/session_registry.rs`
- `orbitdock-server/crates/server/src/runtime/session_command_handler.rs`

Target modules:

- `orbitdock-server/crates/server/src/runtime/session_config_mutations.rs`
- `orbitdock-server/crates/server/src/runtime/session_notice_rows.rs`
- `orbitdock-server/crates/server/src/runtime/plan_snapshots.rs`
- `orbitdock-server/crates/server/src/runtime/session_registry/active_sessions.rs`
- `orbitdock-server/crates/server/src/runtime/session_registry/pending_hooks.rs`
- `orbitdock-server/crates/server/src/runtime/session_registry/ownership.rs`
- `orbitdock-server/crates/server/src/runtime/session_registry/dashboard.rs`
- `orbitdock-server/crates/server/src/runtime/session_registry/missions.rs`

Design intent:

- Keep runtime focused on coordination, not business-state decisions.
- Separate filesystem side effects from config mutation orchestration.
- Break registry concerns into smaller ownership-oriented modules.

### 3. HTTP Transport

Current hot spots:

- `orbitdock-server/crates/server/src/transport/http/mission_control.rs`
- `orbitdock-server/crates/server/src/transport/http/session_lifecycle.rs`

Target modules:

- `orbitdock-server/crates/server/src/transport/http/mission_control/missions.rs`
- `orbitdock-server/crates/server/src/transport/http/mission_control/issues.rs`
- `orbitdock-server/crates/server/src/transport/http/mission_control/tracker_keys.rs`
- `orbitdock-server/crates/server/src/transport/http/mission_control/defaults.rs`
- `orbitdock-server/crates/server/src/transport/http/mission_control/orchestrator.rs`
- `orbitdock-server/crates/server/src/transport/http/mission_control/files.rs`
- `orbitdock-server/crates/server/src/transport/http/sessions/create.rs`
- `orbitdock-server/crates/server/src/transport/http/sessions/config.rs`
- `orbitdock-server/crates/server/src/transport/http/sessions/lifecycle.rs`
- `orbitdock-server/crates/server/src/transport/http/sessions/fork.rs`
- `orbitdock-server/crates/server/src/transport/http/sessions/codex_config.rs`

Design intent:

- Keep handlers narrow and endpoint-family specific.
- Avoid mixing CRUD, credentials, orchestrator control, and response composition in the same file.

### 4. Persistence

Current hot spots:

- `orbitdock-server/crates/server/src/infrastructure/persistence/mod.rs`
- `orbitdock-server/crates/server/src/infrastructure/persistence/session_reads.rs`
- `orbitdock-server/crates/server/src/infrastructure/persistence/mission_control.rs`

Target modules:

- `orbitdock-server/crates/server/src/infrastructure/persistence/session_writes.rs`
- `orbitdock-server/crates/server/src/infrastructure/persistence/mission_writes.rs`
- `orbitdock-server/crates/server/src/infrastructure/persistence/approval_writes.rs`
- `orbitdock-server/crates/server/src/infrastructure/persistence/review_writes.rs`
- `orbitdock-server/crates/server/src/infrastructure/persistence/sync_writes.rs`
- `orbitdock-server/crates/server/src/infrastructure/persistence/startup_recovery.rs`
- `orbitdock-server/crates/server/src/infrastructure/persistence/session_hydration.rs`
- `orbitdock-server/crates/server/src/infrastructure/persistence/ownership_reads.rs`

Design intent:

- Preserve one write entrypoint while splitting the giant persistence executor by family.
- Separate startup recovery from ordinary read paths.
- Make hydration logic and ownership lookup logic easier to reason about and test.

### 5. Claude Hook Translation

Current hotspot:

- `orbitdock-server/crates/server/src/connectors/claude_hooks/handler.rs`

Target modules:

- `orbitdock-server/crates/server/src/connectors/claude_hooks/routing.rs`
- `orbitdock-server/crates/server/src/connectors/claude_hooks/session_start.rs`
- `orbitdock-server/crates/server/src/connectors/claude_hooks/status_events.rs`
- `orbitdock-server/crates/server/src/connectors/claude_hooks/tool_events.rs`
- `orbitdock-server/crates/server/src/connectors/claude_hooks/subagent_events.rs`
- `orbitdock-server/crates/server/src/connectors/claude_hooks/transcript_sync.rs`

Design intent:

- Keep provider payload handling grouped by hook family.
- Make connector code translate and route, not own durable business logic.

### 6. Codex Config Runtime Support

Current hotspot:

- `orbitdock-server/crates/server/src/runtime/codex_config.rs`

Target modules:

- `orbitdock-server/crates/server/src/runtime/codex_config/types.rs`
- `orbitdock-server/crates/server/src/runtime/codex_config/resolver.rs`
- `orbitdock-server/crates/server/src/runtime/codex_config/catalog.rs`
- `orbitdock-server/crates/server/src/runtime/codex_config/documents.rs`
- `orbitdock-server/crates/server/src/runtime/codex_config/rpc_client.rs`
- `orbitdock-server/crates/server/src/runtime/codex_config/binary_discovery.rs`

Design intent:

- Separate DTOs, config resolution, JSON-RPC communication, document rendering, and binary lookup.
- Prevent config transport concerns from becoming runtime business logic by accident.

### 7. Mission Config Domain

Current hotspot:

- `orbitdock-server/crates/server/src/domain/mission_control/config.rs`

Target modules:

- `orbitdock-server/crates/server/src/domain/mission_control/config/model.rs`
- `orbitdock-server/crates/server/src/domain/mission_control/config/parser.rs`
- `orbitdock-server/crates/server/src/domain/mission_control/config/serializer.rs`
- `orbitdock-server/crates/server/src/domain/mission_control/config/migration.rs`
- `orbitdock-server/crates/server/src/domain/mission_control/config/scaffold.rs`

Design intent:

- Keep config schema, parse/serialize logic, legacy migration, and scaffold generation separate.
- Make config transforms more obviously pure and testable.

## Ordered Phases

### Phase 1: Extract the Sessions Functional Core

- [x] Split `domain/sessions/session.rs` into state, conversation, approvals, snapshot, and restore modules.
- [ ] Introduce a thinner actor-owned runtime shell for session state.
- [x] Keep behavior identical while moving pure logic into pure functions.
- [x] Add or preserve focused tests for row sequencing, unread counts, approval queueing, and snapshot projection.

Why this phase is first:

- It is the biggest structural bottleneck.
- It establishes the functional-core pattern the rest of the refactor should follow.

Done when:

- [ ] `SessionHandle` mostly delegates instead of implementing business rules directly.
- [x] Conversation and approval logic can be tested without actor setup or IO.

Progress note:

- `conversation_state.rs`, `approval_state.rs`, `snapshot.rs`, and `restore.rs` were added and wired into `session.rs`.
- A follow-up `code-simplifier` pass removed duplicate test attributes, deleted an unused helper, and added a small `SessionHandle::conversation_state()` delegator to keep the shell readable without changing behavior.
- `cargo fmt --all` passed on 2026-04-09.
- `cargo check -p orbitdock` passed on 2026-04-09.
- `cargo test -p orbitdock-server domain::sessions --lib` passed on 2026-04-09 with 34 tests passing.
- `make rust-check` passed on 2026-04-09.
- `make rust-check-workspace` passed on 2026-04-09.
- `make rust-test` passed on 2026-04-09.
- Mutation-path grep checks were re-run on 2026-04-09:
  - `rg "ApplyDelta \\{ persist_op: None \\}" orbitdock-server/crates/server/src docs/ARCHITECTURE.md`
  - `rg "ProcessEvent" orbitdock-server/crates/server/src`

### Phase 2: Refactor Runtime into Coordination Modules

- [x] Split config mutations, notice-row construction, and plan snapshot IO.
- [x] Break `SessionRegistry` into smaller internal ownership modules.
- [x] Keep `runtime/` focused on command flow, effect execution, and caches.

Why this phase is next:

- It reduces orchestration sprawl once the session domain is cleaner.
- It prepares transport and connectors to target narrower runtime APIs.

Done when:

- [x] Runtime modules no longer mix pure notice rendering with filesystem or actor wiring.
- [x] Registry responsibilities are easier to locate and reason about.

Progress note:

- `session_mutations.rs` now delegates plan snapshotting, config notice construction, and session lifecycle side effects into `config_notices.rs`, `plan_snapshots.rs`, and `session_lifecycle.rs`.
- `session_registry.rs` now delegates ownership lookup, pending hook caching, missions snapshot state, dashboard publication, and session summary/list access into smaller sibling modules under `runtime/session_registry/`.
- The registry helpers keep the mutable shell in runtime while leaving the business rules in the domain layer.
- `cargo fmt --all` passed on 2026-04-09.
- `cargo check -p orbitdock` passed on 2026-04-09.
- `make rust-check` passed on 2026-04-09 after integration.
- `make rust-check-workspace` passed on 2026-04-09 after integration.
- `make rust-test` passed on 2026-04-09 after integration.

### Phase 3: Split Transport by Endpoint Family

- [x] Split mission-control handlers into mission, issue, key, defaults, orchestrator, and file modules.
- [x] Split session lifecycle handlers into create, config, lifecycle, fork, and Codex config modules.
- [x] Keep transport files thin and mapping-focused.
- [x] Split `session_lifecycle.rs` into coherent submodules under `transport/http/session_lifecycle/`.

Why this phase is next:

- It cleans the outermost layer after domain and runtime seams are clearer.
- It lowers the odds of new business logic getting reintroduced into transport.

Progress note:

- `session_lifecycle.rs` was split into `common.rs`, `create.rs`, `codex_config.rs`, `fork.rs`, `mutations.rs`, `resume.rs`, `takeover.rs`, and `mod.rs` under `transport/http/session_lifecycle/`.
- `mission_control.rs` now acts as a façade for the remaining mission CRUD flow and re-exports endpoint families split into `defaults.rs`, `tracker_keys.rs`, `orchestrator.rs`, `issue_reports.rs`, and `files.rs`.
- `transport/http/mod.rs` kept the same public re-exports, so the router and callers still see the same endpoint surface.
- `cargo fmt --all` passed on 2026-04-09 for the touched transport files.
- `cargo check -p orbitdock-server` passed on 2026-04-09 after transport integration.
- `make rust-test` passed on 2026-04-09 after the transport split, including `transport::http::session_lifecycle::*` and `transport::http::mission_control::*` coverage.

Done when:

- [x] Each handler module maps to one coherent API family.
- [x] Business decisions are delegated downward instead of accumulating in handler files.

### Phase 4: Split Persistence by Read and Write Family

- [ ] Break the persistence write executor into family-specific modules.
- [x] Separate startup recovery, hydration, and ownership reads.
- [ ] Preserve the single-writer path and existing transactional guarantees.

Why this phase is next:

- It is easier to split once the surrounding runtime and transport APIs are cleaner.
- It makes persistence responsibilities more explicit without changing the authority model.

Done when:

- [ ] No single persistence file acts like the entire database layer.
- [ ] Write-family and read-family responsibilities are clearly separated.

Progress note:

- `session_reads.rs` now delegates into `startup_recovery.rs`, `session_hydration.rs`, and `ownership_reads.rs` under `infrastructure/persistence/session_reads/`.
- The single-writer executor in `persistence/mod.rs` is still centralized and remains the main unfinished piece for this phase.
- `cargo check -p orbitdock-server` passed on 2026-04-09 with the split read path in place.

### Phase 5: Split Connector and Runtime Support Buckets

- [ ] Split Claude hook handling by hook family.
- [ ] Split Codex config support into types, resolution, transport, and binary discovery.
- [ ] Split mission config domain helpers into model/parser/serializer/migration/scaffold modules.

Why this phase is last:

- These areas benefit from the patterns established in the earlier phases.
- They are easier to clean once session and runtime boundaries are already stronger.

Done when:

- [ ] Connector code is mostly translation and routing.
- [ ] Runtime support modules are not mixing transport, business policy, and environment probing.

Progress note:

- Claude hook handling now delegates routing and subagent update concerns into `connectors/claude_hooks/routing.rs` and `connectors/claude_hooks/subagent_updates.rs`, with `handler.rs` correspondingly reduced.
- Codex config support now has a first extracted support module in `runtime/codex_config_types.rs`, but the resolver, documents, RPC, and binary-discovery concerns are still housed in `runtime/codex_config.rs`.
- Mission config domain types now have a first extracted support module in `domain/mission_control/config_model.rs`, while parser/serializer/migration/scaffold logic still remains in `config.rs`.
- `cargo check -p orbitdock-server`, `make rust-check`, `make rust-check-workspace`, and `make rust-test` all passed on 2026-04-09 with these intermediate support splits in place.

## Files To Modify First

- `orbitdock-server/crates/server/src/domain/sessions/session.rs`
- `orbitdock-server/crates/server/src/domain/sessions/mod.rs`
- `orbitdock-server/crates/server/src/runtime/session_mutations.rs`
- `orbitdock-server/crates/server/src/runtime/session_registry.rs`
- `orbitdock-server/crates/server/src/runtime/mod.rs`

## Implementation Order

1. Extract the sessions domain into pure submodules.
2. Introduce a thinner runtime shell around the extracted session logic.
3. Split runtime orchestration helpers by responsibility.
4. Split transport handlers by endpoint family.
5. Split persistence execution and hydration by family.
6. Split connector translation modules and supporting runtime/config modules.

## Risks And Mitigations

- [ ] Risk: accidentally introducing a second source of truth during module extraction.
  Mitigation: keep `ProcessEvent` as the default mutation path and review each moved function for authority ownership.
- [ ] Risk: moving IO into domain modules while “just reorganizing.”
  Mitigation: keep all filesystem, DB, process, and broadcast work in `runtime/` or `infrastructure/`.
- [ ] Risk: preserving behavior by copy-pasting mutable helpers into new files.
  Mitigation: prefer pure functions with explicit inputs and outputs, even if the shell must adapt around them.
- [ ] Risk: conversation-row sequencing regressions.
  Mitigation: keep sequence assignment and persistence on the current single-writer path and add focused tests around row ordering and paging.

## Verification

- [x] Run `make rust-check`
- [x] Run `make rust-check-workspace`
- [x] Run `make rust-test`
- [x] Run targeted tests for any touched session, persistence, or transport area.
- [x] Grep for mutation-path drift:
  - `rg "ApplyDelta \\{ persist_op: None \\}" orbitdock-server/crates/server/src docs/ARCHITECTURE.md`
  - `rg "ProcessEvent" orbitdock-server/crates/server/src`
- [x] Review each moved module with one question: does this module decide business truth, or only coordinate it?

## Definition Of Done

- [ ] The server layout reflects authority boundaries instead of feature buckets alone.
- [ ] Business rules are easier to find in pure modules under `domain/`.
- [ ] Runtime is coordination-heavy but decision-light.
- [ ] Transport is mapping-heavy but policy-light.
- [ ] Persistence preserves the single-writer and server-authoritative model.
- [ ] The sessions slice sets a clear pattern for future refactors: pure core, mutable shell, explicit effects.
