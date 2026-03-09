# Server Single-Binary CLI Plan

## Goal

Keep `orbitdock` as a single binary while cleaning up the workspace boundaries so command parsing and user-facing dispatch live in `crates/cli`, and daemon/runtime code lives in `crates/server`.

This is not just a folder cleanup inside `crates/server/src`. The real issue is that `crates/server` is currently doing three jobs at once:

- server runtime and daemon startup
- top-level `orbitdock` binary wiring
- server-admin command handling through `cmd_*` modules

At the same time, `crates/cli` already exists and is organized like the natural home for command definitions and dispatch.

## Current Assessment

### What is already clean

- `crates/protocol` is small and focused
- `crates/connector-core` is small and focused
- `crates/connector-claude` is coherent
- `crates/connector-codex` is coherent
- `crates/cli` already has a clean internal shape:
  - `cli.rs`
  - `client/`
  - `commands/`
  - `output/`

### What is not clean

`crates/server` currently owns:

- the daemon
- the binary entrypoint
- server-admin and install/setup flows
- translation glue into `orbitdock_cli`
- a large root-level module graph in `src/`

The biggest smell is that `crates/server/src/main.rs` is acting as:

- CLI parser
- admin command dispatcher
- client command translator
- daemon bootstrapper

That makes the crate boundary blurry before we even get to the folder layout inside `src/`.

## Desired End State

### Ownership

`crates/cli` should own:

- the `orbitdock` command tree
- all argument parsing
- completions
- all user-facing dispatch

`crates/server` should own:

- daemon startup
- runtime modules
- persistence
- transport
- domain logic
- reusable admin/setup/install primitives

Important rule:

- `crates/server` provides capabilities
- `crates/cli` provides UX

## Functional Direction

This refactor should also push the codebase toward a more functional and pure design wherever it is practical.

That does not mean forcing everything into abstract purity. It means being disciplined about where side effects live and making decision logic easy to reason about, test, and move between crates.

### Core rule

Prefer:

- pure functions for classification, normalization, parsing, and decision-making
- explicit inputs and outputs
- side effects at the edges
- small orchestration layers that call pure operations

Avoid:

- command modules that mix argument parsing, branching logic, filesystem writes, process launching, and output formatting in one place
- helpers that read global state internally when inputs could be passed explicitly
- logic that only exists as imperative glue inside `main.rs`

### What this means in practice

#### `crates/cli`

`crates/cli` should be a thin orchestration layer:

- parse arguments
- resolve config
- call a focused operation
- render output
- return an exit code

Command handlers should stay small. If a handler contains branching or transformation logic that can be pure, extract it.

#### `crates/server`

`crates/server` should separate:

- pure domain logic
- infrastructure adapters
- orchestration

Examples:

- setup mode resolution should be pure
- token display formatting rules should be pure
- status classification should be pure
- file layout and path resolution logic should be as pure as possible
- install and hook operations should be thin wrappers around pure planning logic plus explicit I/O

### Side-effect boundaries

Side effects should be concentrated in modules that clearly own them:

- filesystem writes
- process execution
- HTTP forwarding
- service installation
- environment mutation
- SQLite writes

Those modules should accept already-computed inputs from pure logic, rather than deciding everything internally.

### Recommended extraction pattern

When moving code out of `cmd_*` modules, use this split:

1. pure planning function
2. side-effect executor
3. CLI renderer / UX wrapper

Examples:

- `plan_install_hooks(config) -> HookInstallPlan`
- `apply_install_hooks(plan, io) -> Result<...>`
- `render_install_hooks_result(result) -> String`

- `resolve_setup_mode(flags, env, defaults) -> SetupPlan`
- `run_setup_plan(plan, services) -> Result<...>`

- `classify_status(...) -> StatusSummary`
- `render_status(summary, output_mode) -> ...`

This pattern should reduce the amount of code that is hard to test and hard to move.

### Where purity matters most

The highest-value targets are:

- setup and remote-setup decision logic
- status/doctor classification logic
- path and config resolution
- hook payload shaping and normalization
- command-to-operation mapping
- session and worktree state transitions

These are the places where pure functions will most improve both structure and tests.

### Where pragmatism wins

Some code will remain effectful by nature:

- daemon startup
- WebSocket and HTTP transport
- filesystem mutation
- process spawning
- persistence writes

The goal is not to eliminate effects. The goal is to stop hiding business logic inside effectful code paths.

### Binary model

We keep a single binary named `orbitdock`.

The preferred end state is:

- `crates/cli` owns the real binary entrypoint
- `crates/server` becomes library-first

If needed during migration, `crates/server` can temporarily keep the binary while `crates/cli` grows the missing command surface, but that should be treated as a short-lived transitional state.

## Target Structure

### `crates/cli`

This crate becomes the canonical home for all top-level commands.

Suggested structure:

```text
crates/cli/
  src/
    main.rs
    lib.rs
    cli.rs
    client/
    commands/
      approval.rs
      codex.rs
      fs.rs
      health.rs
      mcp.rs
      model.rs
      review.rs
      server.rs
      session.rs
      shell.rs
      usage.rs
      worktree.rs
      admin.rs
    admin/
      init.rs
      install_hooks.rs
      hook_forward.rs
      install_service.rs
      ensure_path.rs
      status.rs
      doctor.rs
      setup.rs
      remote_setup.rs
      tunnel.rs
      pair.rs
      start.rs
    output/
```

Notes:

- `commands/` remains the command dispatch layer
- `admin/` holds implementation for server-admin flows
- `commands/admin.rs` can map CLI variants into the `admin/*` operations
- command names should remain compatible with the current CLI surface

### `crates/server`

This crate should stop owning CLI command modules and focus on runtime code only.

Suggested structure:

```text
crates/server/
  src/
    lib.rs
    app/
    connectors/
    domain/
    infrastructure/
    state/
    transport/
```

More concretely:

```text
crates/server/src/
  lib.rs
  app/
    bootstrap.rs
    runtime.rs
  connectors/
    claude.rs
    codex.rs
    hooks.rs
    rollout_watcher.rs
    subagent_parser.rs
  domain/
    sessions/
    worktrees/
    git/
  infrastructure/
    auth.rs
    auth_tokens.rs
    crypto.rs
    images.rs
    logging.rs
    metrics.rs
    migration_runner.rs
    paths.rs
    persistence/
    shell.rs
    usage_probe.rs
  state/
    registry.rs
  transport/
    http/
    websocket/
```

The important part is not the exact directory names. The important part is that `cmd_*` disappears from this crate entirely.

## Server Admin Commands: Where They Go

These current `crates/server/src/cmd_*` files are crate-boundary tech debt and should move out of the server crate’s root command surface:

- `cmd_doctor.rs`
- `cmd_ensure_path.rs`
- `cmd_hook_forward.rs`
- `cmd_init.rs`
- `cmd_install_hooks.rs`
- `cmd_install_service.rs`
- `cmd_pair.rs`
- `cmd_remote_setup.rs`
- `cmd_setup.rs`
- `cmd_status.rs`
- `cmd_tunnel.rs`

### New ownership model

User-facing command ownership moves to `crates/cli`.

Capability ownership stays in `crates/server`.

Examples:

- hook install logic becomes `orbitdock_server::admin::hooks::*`
- service install logic becomes `orbitdock_server::admin::service::*`
- token management becomes `orbitdock_server::admin::tokens::*`
- server startup becomes `orbitdock_server::app::run(...)`

Then `crates/cli` calls those APIs.

### Naming cleanup

Inside `crates/server`, rename command-shaped modules to capability-shaped modules.

Examples:

- `cmd_install_hooks.rs` -> `admin/hooks.rs`
- `cmd_install_service.rs` -> `admin/service.rs`
- `cmd_status.rs` -> `admin/status.rs`
- `cmd_setup.rs` -> `admin/setup.rs`
- `cmd_hook_forward.rs` -> `admin/hook_forward.rs`

The implementation can stay roughly the same at first. The point is to remove CLI ownership from the server crate.

## Migration Plan

### Phase 1: Make `crates/server` a proper library

Add `crates/server/src/lib.rs` and expose stable APIs for:

- starting the daemon
- token generation/list/revoke
- install-hooks operations
- install-service operations
- hook-forward transport config and forwarding
- doctor/status/setup primitives

This phase should avoid major behavior changes. It is mainly about creating a clean API boundary.

### Phase 2: Move admin command parsing into `crates/cli`

Extend `crates/cli` so it owns all top-level command parsing, including:

- `start`
- `init`
- `install-hooks`
- `hook-forward`
- `install-service`
- `ensure-path`
- `status`
- `generate-token`
- `list-tokens`
- `revoke-token`
- `doctor`
- `setup`
- `remote-setup`
- `tunnel`
- `pair`
- `completions`

This should preserve the current user-facing command names and flags.

### Phase 3: Replace translation glue in `crates/server`

Remove the awkward middle layer in `crates/server/src/main.rs` where it:

- parses the full CLI
- dispatches some commands locally
- translates other commands into `orbitdock_cli::cli::Command`
- forwards them into `orbitdock_cli::dispatch`

That glue should disappear once `crates/cli` owns the real command tree.

### Phase 4: Move the binary entrypoint

Preferred end state:

- `crates/cli/src/main.rs` becomes the single binary entrypoint
- `crates/server` becomes library-only

If there is a reason to keep the `[[bin]]` declaration in `crates/server` for a short period, that can be transitional, but the long-term shape should not leave the binary entrypoint in the runtime crate.

### Phase 5: Reorganize `crates/server/src`

After the CLI/admin extraction is complete, reorganize the server runtime into logical module groups:

- domain
- transport
- infrastructure
- connectors
- app/bootstrap

This is when the existing `src/` sprawl should be cleaned up.

Important sequencing rule:

- do not start with a folder-only cleanup in `crates/server/src`
- fix binary and crate ownership first

## Compatibility Rules

This refactor should be internal only. Preserve:

- binary name: `orbitdock`
- top-level command names
- flag names
- environment variable names
- output behavior

The goal is better boundaries and code organization, not a user-facing CLI redesign.

## Testing Strategy

The current plan should explicitly treat tests as part of the cleanup, not as a final validation footnote.

This workspace likely has the same boundary problem in tests that it has in production code:

- tests may be following file layout instead of user-visible behavior
- tests may be coupled to `main.rs` glue that should disappear
- tests may be exercising internal command translation instead of real command outcomes
- tests may be missing clear separation between pure logic, integration boundaries, and full CLI workflows

### Testing principles for this refactor

- test user outcomes, not internal dispatch details
- do not mock our own code just to preserve the current structure
- add pure tests where extracting logic makes that possible
- use integration tests for real command behavior and server boundaries
- avoid arbitrary sleeps, polling loops, and timing-based assertions

### What should be tested

#### 1. CLI outcome tests

Once `crates/cli` owns the command tree, tests should verify outcomes like:

- `orbitdock health` returns the expected status against a real test server
- `orbitdock session list` hits the expected endpoint and renders the expected output shape
- `orbitdock start` invokes server startup through the public server API
- `orbitdock install-hooks` updates the expected config files

These should not assert that a particular translation function or intermediate enum conversion was called.

#### 2. Server admin operation tests

The reusable admin/setup/install logic extracted into `crates/server` should have focused tests around real outcomes:

- token generation creates a valid stored token record
- install-hooks writes the expected hook configuration
- install-service produces the expected service definition
- status/doctor commands report the right state for real filesystem and process conditions

Where possible, use temp directories and real files rather than mocks.

#### 3. Pure logic tests

As command-shaped modules become capability-shaped modules, extract and test pure logic directly:

- argument normalization
- config resolution
- status classification
- setup decision logic
- tunnel/pair URL generation
- output-independent planning logic

These should become fast unit tests with no I/O.

#### 4. End-to-end binary confidence tests

We should have a small number of end-to-end tests that exercise the single binary surface:

- a server-admin command path
- a client command path
- a daemon startup path

The goal is not exhaustive CLI coverage. The goal is proving that the single-binary contract still works after ownership moves from `crates/server` to `crates/cli`.

### Refactor-specific test plan

Each phase should carry its own verification:

- Phase 1: add tests around new `crates/server` library APIs before deleting old glue
- Phase 2: add or update `crates/cli` tests for migrated command parsing and dispatch
- Phase 3: remove tests that only validate translation glue or module placement
- Phase 4: add a small binary-level integration pass to confirm the single entrypoint still behaves correctly
- Phase 5: clean up duplicated or low-value tests that only existed because responsibilities were split awkwardly

### Testing smells to remove during this work

- tests that assert internal enum translation instead of command results
- tests that mock internal server/admin modules
- tests that use arbitrary sleeps instead of waiting for a concrete event or observable state
- tests that are organized around current files rather than stable behavior
- tests that exist only because logic was trapped inside an effectful wrapper instead of a pure function

### Success criteria for tests

The refactor is in good shape when:

- command tests are written against observable command behavior
- extracted server APIs have direct tests at the right level
- pure setup/status logic is covered with fast deterministic tests
- the single-binary flow has a few high-confidence integration tests
- deleting glue code also lets us delete glue tests

## What Not To Do

- Do not keep command parsing split between `crates/server` and `crates/cli`
- Do not leave `cmd_*` modules living in `crates/server` after the dust settles
- Do not move admin logic straight into ad hoc files inside `crates/cli` if that duplicates server capabilities
- Do not start by reorganizing `crates/server/src` before fixing the crate boundary problem

## Concrete Mapping

This is the intended ownership shift.

| Current location | Target home | Notes |
| --- | --- | --- |
| `crates/server/src/main.rs` CLI parsing | `crates/cli` | `crates/cli` should own the canonical command tree |
| `crates/server/src/main.rs` daemon startup | `crates/server::app` | reusable runtime entrypoint |
| `crates/server/src/cmd_init.rs` | `crates/cli::admin` calling `crates/server::admin` | CLI UX in `cli`, implementation in `server` |
| `crates/server/src/cmd_install_hooks.rs` | `crates/cli::admin` calling `crates/server::admin::hooks` | same behavior, cleaner ownership |
| `crates/server/src/cmd_hook_forward.rs` | `crates/cli::admin` calling `crates/server::admin::hook_forward` | keep hidden/internal semantics if needed |
| `crates/server/src/cmd_install_service.rs` | `crates/cli::admin` calling `crates/server::admin::service` | platform install logic should be reusable |
| `crates/server/src/cmd_ensure_path.rs` | `crates/cli::admin` calling `crates/server::admin::paths` | |
| `crates/server/src/cmd_status.rs` | `crates/cli::admin` calling `crates/server::admin::status` | token and local install status helpers |
| `crates/server/src/cmd_doctor.rs` | `crates/cli::admin` calling `crates/server::admin::doctor` | |
| `crates/server/src/cmd_setup.rs` | `crates/cli::admin` calling `crates/server::admin::setup` | orchestration stays behind server APIs |
| `crates/server/src/cmd_remote_setup.rs` | `crates/cli::admin` calling `crates/server::admin::setup` | probably folded into same module |
| `crates/server/src/cmd_tunnel.rs` | `crates/cli::admin` calling `crates/server::admin::tunnel` | |
| `crates/server/src/cmd_pair.rs` | `crates/cli::admin` calling `crates/server::admin::pairing` | |

## Success Criteria

This plan is successful when:

- there is still only one `orbitdock` binary
- `crates/cli` owns all command parsing and top-level dispatch
- `crates/server` no longer contains `cmd_*` files
- `crates/server` can be understood as a runtime library instead of a mixed binary/runtime crate
- `crates/server/src/main.rs` is gone or reduced to a trivial transitional shim
- the internal structure of `crates/server/src` becomes straightforward to clean up in a second pass

## Recommended Next Step

Before editing code, produce a narrow implementation checklist that covers:

- Cargo target changes
- new `crates/server/src/lib.rs` exports
- new `crates/cli` command variants
- one-by-one file moves and renames
- compatibility verification after each phase

That will make the refactor mechanical and lower-risk instead of exploratory.

## Phase 2: API and Runtime Design Cleanup

The crate and file structure cleanup is only the first half of the job.

If the real goal is for the OrbitDock server API and runtime surface to feel
well-structured, well-designed, and well-documented, then this plan needs an
explicit second phase after the ownership refactor lands.

This phase is about making the code easier to understand and the public and
internal APIs easier to trust.

### Goal

Refactor the server-side API surface so it is:

- structurally coherent
- explicit about boundaries and ownership
- more functional where practical
- easier to document
- easier to test at the right level

This includes:

- runtime module boundaries
- internal command/query APIs
- HTTP and WebSocket handler structure
- reusable server library APIs called from `crates/cli`
- documentation of what each layer owns and how data moves through it

### Desired End State

By the end of this phase:

- the server runtime layers are obvious from code layout alone
- domain code is mostly free of transport and actor orchestration details
- runtime orchestration code is clearly separate from domain transforms
- pure helper logic lives in support or domain modules, not inside effectful flows
- reusable server APIs have stable names and clear call patterns
- key architectural decisions are documented in repo markdown
- tests reflect API contracts and user-visible behavior instead of legacy glue

## API Design Targets

### 1. Clear Layer Ownership

The code should read cleanly in this direction:

- `transport/` handles protocol concerns
- `runtime/` handles actor orchestration, registries, command routing, and background loops
- `domain/` handles session, worktree, and git domain rules
- `infrastructure/` handles persistence, filesystem, crypto, auth, shell, and metrics
- `support/` handles pure shared helpers and data shaping

Important rule:

- transport can depend on runtime, domain, infrastructure, and support
- runtime can depend on domain, infrastructure, and support
- domain should not depend on transport
- support should stay pure where practical

### 2. Query and Command Separation

The runtime layer should keep clear boundaries between:

- actor commands and mutation flows
- read/query helpers
- background loops
- state registries

Examples of the intended direction:

- `runtime/session_commands.rs`
- `runtime/session_command_handler.rs`
- `runtime/session_queries.rs`
- `runtime/session_registry.rs`
- `runtime/background/*`

The point is not to explode the file count. The point is to stop mixing
commands, read models, state registries, and helper utilities in the same file.

### 3. Domain API Cleanup

The session domain should expose focused types and behaviors, not runtime glue.

Targets:

- keep `SessionHandle` focused on session state and state transitions
- keep conversation DTOs in their own module
- avoid domain code importing transport or runtime-specific protocol helpers
- move general-purpose pure helpers out of orchestration files

Likely remaining follow-ups:

- evaluate whether `SessionHandle` should be split into state plus methods
- reduce direct knowledge of actor command plumbing inside domain-oriented code
- reduce duplicate timestamp and sequence helpers

### 4. Server Library API Cleanup

The reusable APIs exposed from `crates/server` should be intentionally shaped,
not just whatever happened to be pulled out of `main.rs`.

The desired style is:

- explicit input structs for non-trivial operations
- explicit result structs when an operation returns meaningful state
- no hidden global reads when parameters can be passed in
- small, named entrypoints grouped by capability

Examples:

- `app::run_server(ServerRunOptions)`
- `admin::init(...)`
- `admin::install_hooks(...)`
- `admin::status(...)`

If a server API has become a grab bag of side effects, split it into:

1. pure planning
2. effect execution
3. presentation or CLI rendering

### 5. Transport API Cleanup

The HTTP and WebSocket layers should be readable as protocol adapters, not as
places where business logic gets invented.

Targets:

- thin handlers that validate input, call focused operations, and map results
- shared runtime or domain helpers for repeated mutation logic
- fewer transport files reaching deep into persistence directly unless they are
  truly query adapters
- clearer naming for protocol-only helpers versus business operations

### 6. Documentation

This phase should leave the repo easier to navigate for a new contributor.

Add or update documentation for:

- server module ownership and layering
- the single-binary architecture
- runtime data flow:
  - CLI -> server library
  - HTTP/WS -> runtime -> domain -> infrastructure
- session lifecycle flow
- approval flow
- passive versus direct session behavior

Suggested deliverables:

- update this plan with completion notes
- add a short server architecture doc under `docs/`
- add module-level comments where ownership is non-obvious

Documentation should explain:

- what a layer owns
- what it should not own
- where to put new code

### 7. Testing for the API Phase

This phase should keep following the testing philosophy:

- test user outcomes and API contracts
- do not add tests that only pin file layout
- prefer pure tests for extracted transforms
- use integration tests for server library boundaries and transport behavior

Add tests when:

- a boundary becomes clearer and can now be tested directly
- a pure helper is extracted
- a command/query split creates a clearer contract

Delete or rewrite tests when:

- they only validate old glue behavior
- they depend on internal module placement
- they make future restructuring harder

## Phase 2 Execution Plan

### Step 1. Finish runtime extraction

Complete the split between:

- domain session code
- runtime actor code
- runtime queries
- runtime background jobs

Good enough means:

- the remaining responsibilities are clear
- the file names reflect those responsibilities
- new code has an obvious home

### Step 2. Normalize server library APIs

Audit `crates/server` exports and internal admin APIs for:

- inconsistent naming
- hidden input resolution
- command-shaped logic mixed with rendering
- missing result types

Refactor toward explicit operation boundaries.

### Step 3. Simplify transport handlers

Audit `transport/http` and `transport/websocket` for:

- duplicated flow logic
- persistence-heavy handlers that should call runtime/query helpers
- overly stateful handlers
- protocol mapping that belongs in small helpers

### Step 4. Extract and centralize pure helpers

Continue moving pure logic into `support/` or domain modules:

- path derivation
- timestamp formatting/parsing
- message normalization
- state classification
- setup/status planning

This should reduce duplicate logic across runtime, infrastructure, and transport.

### Step 5. Add architecture documentation

Document the final structure once it is stable enough to describe without
immediate churn.

Minimum output:

- one architecture doc under `docs/`
- updated plan notes here
- module comments where the ownership boundary is subtle

## Phase 2 Success Criteria

This second phase is successful when:

- `crates/server` reads like a deliberately layered runtime library
- runtime orchestration is distinct from domain logic
- the internal server APIs have clearer names and ownership
- the most reused pure helpers live outside effectful orchestration code
- the transport layer is thinner and easier to reason about
- the repo contains documentation that explains the architecture clearly
- tests continue to verify behavior at the right level

## Phase 3: Foundation Polish

At this point the server has a real architecture. The final phase is about
making that architecture durable so future work lands in the right place by
default.

This phase is not another broad reorg. It is a focused cleanup pass on the
remaining hotspots, plus a small amount of shared infrastructure to keep tests
and error handling consistent.

### Goal

Leave the server in a place where:

- the remaining large transport files are mostly adapters, not policy centers
- runtime operations are the obvious home for orchestration
- transport and runtime errors have a more consistent shape
- test setup is shared and deterministic
- naming and documentation make it easy to place new code correctly

### Main Targets

#### 1. Finish thinning `session_crud.rs`

The biggest remaining hotspot is:

- `crates/server/src/transport/websocket/handlers/session_crud.rs`

What still belongs lower:

- direct session startup orchestration
- Claude fork orchestration
- Codex fork orchestration
- shared result shaping where HTTP and WebSocket can use the same runtime work

The desired end state is that `session_crud.rs` mostly:

1. parses websocket requests
2. calls focused runtime operations
3. translates outcomes into websocket messages

#### 2. Keep shrinking `transport/websocket/mod.rs`

`transport/websocket/mod.rs` is much better than it was, but it should keep
losing tests and helper logic that belong elsewhere.

Keep only:

- facade wiring
- truly websocket-wide integration tests
- shared websocket-wide exports that are actually transport concerns

Move out:

- helper-specific pure tests
- behavior that belongs in `transport.rs`, `message_groups.rs`, `rest_only_policy.rs`, or runtime helpers

#### 3. Tighten HTTP lifecycle seams

`crates/server/src/transport/http/session_lifecycle.rs` is in much better shape,
but it still deserves another pass so transport does less inline assembly for:

- resume
- takeover
- fork-related responses

The target is the same as websocket:

- parse input
- call runtime operation
- map result

#### 4. Normalize transport/runtime error shaping

There is still repeated assembly of:

- `ServerMessage::Error { code, message, session_id }`
- similar HTTP error mapping branches

We should introduce a small shared error-shaping layer so transport code
does not keep rebuilding the same user-visible error payloads by hand.

This should improve:

- consistency of error codes
- readability of handlers
- reuse between HTTP and WebSocket where appropriate

#### 5. Add shared server test helpers

We fixed the shared data-dir flake, but the next step is to make server test
setup reusable instead of hand-rolled across modules.

Targets:

- one shared helper for test data dir initialization
- one shared helper for `SessionRegistry` test state creation where appropriate
- fewer copy-pasted websocket/http test setup blocks

This follows the testing philosophy:

- test user-visible outcomes
- keep setup deterministic
- remove incidental brittleness caused by test environment duplication

#### 6. Naming and docs polish

We have better naming now, but there is still a mix of:

- `*_policy`
- `*_targets`
- `*_helpers`
- `*_queries`
- `*_subscriptions`

Do a final pass to make naming more self-explanatory and consistent where it
buys clarity.

Also add a short “where new code should go” section to the architecture docs,
with concrete examples for:

- a new runtime operation
- a new pure helper
- a new websocket handler
- a new HTTP endpoint

## Phase 3 Execution Plan

### Step 1. Extract the remaining `session_crud` orchestration

Prioritize:

- direct session startup
- Claude fork orchestration
- Codex fork orchestration

Success means `session_crud.rs` is materially smaller and mostly transport glue.

### Step 2. Reduce websocket facade bulk

Keep moving tests and helper behavior out of `transport/websocket/mod.rs` until
only websocket-wide integration concerns remain there.

### Step 3. Clean up HTTP lifecycle shaping

Apply the same transport-thinning standard to `session_lifecycle.rs` and any
other HTTP lifecycle handlers still doing too much inline work.

### Step 4. Introduce shared error shaping

Create a focused error layer for user-visible transport/runtime errors and adopt
it in the highest-repetition handlers first.

### Step 5. Introduce shared server test helpers

Replace repeated test-environment setup with shared helpers, then simplify the
most duplicated websocket/http/runtime tests onto those helpers.

### Step 6. Final naming and documentation polish

Once the code stops moving, finish the naming pass and update docs so the
architecture explains both the layering and the expected landing spot for new code.

## Phase 3 Parallel Work Plan

This phase is intentionally split into worker-friendly lanes.

### Lane A: `session_crud` runtime extraction

Focus:

- direct session startup
- Claude fork orchestration
- Codex fork orchestration

Primary files:

- `transport/websocket/handlers/session_crud.rs`
- `runtime/session_creation.rs`
- new focused runtime modules as needed

### Lane B: websocket facade and test rehoming

Focus:

- shrink `transport/websocket/mod.rs`
- move tests beside helpers/modules they actually verify

Primary files:

- `transport/websocket/mod.rs`
- `transport/websocket/transport.rs`
- `transport/websocket/message_groups.rs`
- relevant runtime/support modules

### Lane C: HTTP lifecycle thinning and error shaping

Focus:

- reduce inline lifecycle assembly in HTTP
- establish shared transport/runtime error helpers

Primary files:

- `transport/http/session_lifecycle.rs`
- shared transport/runtime error modules

### Lane D: shared test harness and naming/docs polish

Focus:

- reusable server test helpers
- deterministic setup
- naming cleanup that does not overlap deeper runtime changes
- architecture-doc completion

Primary files:

- shared test helper modules
- `docs/server-architecture.md`

## Phase 3 Success Criteria

This phase is successful when:

- `session_crud.rs` is no longer a policy-heavy hotspot
- `transport/websocket/mod.rs` reads like a facade, not a test warehouse
- HTTP lifecycle handlers mostly map requests to runtime operations
- shared transport/runtime error shaping reduces repeated error construction
- server tests use shared deterministic setup helpers
- the architecture docs tell contributors where new code should go
