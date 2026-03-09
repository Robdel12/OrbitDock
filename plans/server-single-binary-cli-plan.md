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
