# Codex `rust-v0.117.0` Support Scope

This is the scope pass for bringing OrbitDock up to Codex `rust-v0.117.0`, released on March 26, 2026.

The short version:

- OrbitDock is currently pinned to `rust-v0.116.0`.
- We already have real Codex support, not a thin wrapper.
- The biggest release-note items split into two buckets:
  - direct-embedding features we mostly already understand
  - app-server-only features that OrbitDock cannot support just by bumping crates

That distinction matters. It changes the size of the work quite a bit.

## What Changed In `0.117.0`

Using `gh`, the release and compare data point to four relevant themes:

1. Plugins became a first-class workflow.
2. Sub-agents moved further into multi-agent v2 with path-based agent addresses like `/root/agent_a`.
3. App-server clients gained `thread/shellCommand`, filesystem watch RPCs, and remote websocket auth.
4. The app-server-backed TUI became the default path upstream.

The direct release-note language is useful here:

- plugins are now first-class
- sub-agents use path-based addresses
- app-server clients can send `!` shell commands
- app-server clients can watch filesystem changes
- remote websocket app-server connections support bearer-token auth

## What OrbitDock Already Has

OrbitDock is not starting from zero.

### Direct Codex integration already exists

The Rust workspace is pinned to `rust-v0.116.0` in `orbitdock-server/Cargo.toml`, and the main live session path embeds `codex-core` directly through the connector in `orbitdock-server/crates/connector-codex/src/lib.rs`.

That connector already handles:

- streamed agent/tool events
- approvals
- dynamic tool calls
- collab agent lifecycle events
- subagent persistence
- plugin list/install/uninstall flows

### Plugin backend is already partially built

OrbitDock already exposes HTTP endpoints for:

- `GET /api/sessions/{id}/plugins`
- `POST /api/sessions/{id}/plugins/install`
- `POST /api/sessions/{id}/plugins/uninstall`

Those are wired through `orbitdock-server/crates/server/src/transport/http/capabilities.rs` into `orbitdock-server/crates/connector-codex/src/session_ops.rs`.

That means the server side is ahead of the product surface.

### Subagent UI already exists

The native app already has a worker roster and worker detail sidecar in:

- `OrbitDockNative/OrbitDock/Views/SessionDetail/SessionWorkerRoster.swift`
- `OrbitDockNative/OrbitDock/Views/SessionDetail/SessionDetailViewModel.swift`

The session model also already carries:

- `subagents`
- `subagentTools`
- `subagentMessages`

So OrbitDock already thinks in terms of first-class workers.

### OrbitDock already talks to Codex app-server in a narrow way

We already spawn `codex app-server` for:

- config inspection in `orbitdock-server/crates/server/src/runtime/codex_config.rs`
- account/rate-limit reads in `orbitdock-server/crates/server/src/infrastructure/usage_probe.rs`

But that is not a persistent app-server session runtime. It is one-shot request/response usage.

## The Big Boundary: Direct vs App-Server

This is the most important scoping conclusion.

Some of the flashy `0.117.0` features are not general Codex-core capabilities. They are app-server protocol features.

That includes:

- `thread/shellCommand`
- `fs/watch`
- `fs/unwatch`
- `fs/changed`
- remote websocket auth for app-server clients

OrbitDock does not currently run Codex sessions through app-server. Our real session path is still direct embedding through `codex-core`.

So if we want true first-class support for those features, we need a new OrbitDock app-server session mode. A crate bump alone will not get us there.

## Feature-By-Feature Scope

## 1. Plugins

This is the best first target.

Why:

- the backend is already mostly there
- the release made plugins a stable, user-facing workflow
- OrbitDock currently has a gap between server capability and actual product UX

### Current OrbitDock state

Server support exists for:

- listing plugin marketplaces
- installing plugins
- uninstalling plugins
- filtering by session source and product restriction
- optional remote sync

### Current gaps

- the native client does not expose plugin APIs through `SessionsClient`
- there is no first-class plugin UI in the app
- install results currently throw away part of the upstream response

That last point is important. In `orbitdock-server/crates/connector-codex/src/session_ops.rs`, `install_plugin()` currently returns:

- `auth_policy`
- `apps_needing_auth: Vec::new()`

Upstream `0.117.0` expects plugin install to surface apps that still need auth. So even where we have server support, we are not yet exposing the full workflow.

### Scope to make plugins first-class in OrbitDock

- bump Codex crates to `rust-v0.117.0`
- verify `PluginListResponse`, `PluginReadResponse`, `PluginInstallResponse`, and related types still compile cleanly
- add native client API methods for plugin list/read/install/uninstall
- add a session-level plugin browser UI
- show install state, auth state, and marketplace metadata
- surface `apps_needing_auth` after install
- refresh MCP/app/tool inventory after install or uninstall

### Effort

Medium. Mostly additive. Good candidate for the first implementation slice.

## 2. Sub-agents and multi-agent v2

OrbitDock is closer here than the release notes might suggest.

### Current OrbitDock state

The direct connector already maps collab agent events in `orbitdock-server/crates/connector-codex/src/event_mapping/collab.rs`.

The server already persists subagents.

The native app already renders a worker roster.

### Why this is still not “done”

Multi-agent v2 changed the upstream model in a few meaningful ways:

- path-based agent IDs like `/root/agent_a`
- structured inter-agent communication
- agent listing improvements
- watcher-driven updates around v2 communication

OrbitDock’s high-level worker ID handling is probably fine because IDs are plain strings everywhere.

The risk is lower-level compatibility:

- drill-down views rely on transcript parsing and rollout interpretation
- subagent transcript parsing in `orbitdock-server/crates/server/src/connectors/subagent_parser.rs` is tuned to older message shapes
- the old rollout parser path was removed when OrbitDock dropped passive rollout watching in favor of a hook-first Codex design

### Scope to harden subagent support

- bump Codex crates to `rust-v0.117.0`
- validate collab event enum changes compile cleanly
- verify worker roster behavior with path-based IDs
- update rollout parsing for new multi-agent v2 communication events
- update transcript parsing for worker drill-down, if upstream transcript shape changed
- test parent/child worker relationships with path-based parents
- test mixed states like running, interrupted, completed, failed, not found

### Effort

Medium. Lower risk than app-server work, but more subtle than it first looks.

## 3. `!` shell commands from app-server clients

This is not a small feature for OrbitDock.

### What upstream added

Upstream added `thread/shellCommand` so app-server clients can implement `!` shell commands.

The generated schema for `ThreadShellCommandParams` is especially important:

- it sends a raw shell command string
- it preserves shell syntax like pipes and redirects
- it runs unsandboxed with full access rather than inheriting the thread sandbox policy

That last point makes this a product and security decision, not just a transport detail.

### Current OrbitDock state

OrbitDock does not run Codex conversations over app-server today.

We only use app-server for narrow utility calls like config reads and rate-limit reads.

### Scope required for real support

- add a persistent app-server-backed Codex session mode in OrbitDock
- map OrbitDock sessions to app-server `thread/*` lifecycle
- render app-server item streams as OrbitDock conversation rows
- support app-server approvals and interruptions
- explicitly decide how OrbitDock exposes an unsandboxed `!` shell path
- decide whether this is opt-in, hidden behind a capability, or intentionally not supported

### Effort

Large. This is a new integration mode, not a patch.

## 4. Filesystem watch and remote websocket auth

These land in the same bucket as `!` shell commands.

### What upstream added

App-server now supports:

- `fs/watch`
- `fs/unwatch`
- `fs/changed`
- remote websocket auth with bearer tokens during websocket upgrade

### Current OrbitDock state

OrbitDock has its own server-authoritative transport model already:

- HTTP for bootstrap and heavy reads
- WebSocket for light realtime deltas and refetch hints

For OrbitDock itself, filesystem watch is only useful if we decide to become an app-server client for live Codex sessions.

Remote websocket auth matters if we want OrbitDock to connect to a remote Codex app-server instead of spawning local Codex or embedding `codex-core`.

### Effort

Large when taken seriously. This belongs in the same project as app-server session mode.

## Recommended Plan

If the goal is to add real first-class support without disappearing into a giant rewrite, the best order is:

### Phase 1: Safe upgrade plus plugin productization

- bump all Codex crates from `rust-v0.116.0` to `rust-v0.117.0`
- fix compile fallout
- verify direct-session behavior in a real session
- expose plugin APIs to the native app
- build a first-class plugin browser/install flow
- carry through auth follow-up state after install

Why this first:

- users get visible value quickly
- most of the server plumbing already exists
- it exercises the release in a low-risk way

### Phase 2: Multi-agent v2 hardening

- validate path-based worker IDs
- harden rollout parsing and worker drill-down
- improve worker messaging surfaces for structured inter-agent communication

Why second:

- OrbitDock already has worker UI
- we can make the existing experience more trustworthy without changing the whole architecture

### Phase 3: Decide whether OrbitDock should support app-server session mode

This is the fork-in-the-road decision.

If yes, scope a dedicated project for:

- persistent app-server thread runtime
- session mapping
- item/event translation
- approval handling
- shell command policy
- optional remote Codex connections

If no, then we should explicitly say OrbitDock supports:

- direct embedded Codex sessions
- passive rollout watching
- plugin workflows
- multi-agent support through the direct connector

And we should leave app-server-only features out of scope on purpose.

## My Recommendation

Start with Phase 1.

That means:

1. bump to `rust-v0.117.0`
2. finish the plugin product surface
3. validate multi-agent v2 compatibility while doing the bump
4. defer app-server session mode to a separate design pass

This gives OrbitDock meaningful `0.117.0` value without forcing us to pretend that app-server and direct embedding are the same thing.

They are not.

## Concrete Touchpoints

If we take the recommended Phase 1 path, these are the main files I would expect to touch first:

- `orbitdock-server/Cargo.toml`
- `orbitdock-server/Cargo.lock`
- `orbitdock-server/crates/connector-codex/src/session_ops.rs`
- `orbitdock-server/crates/server/src/transport/http/capabilities.rs`
- `OrbitDockNative/OrbitDock/Services/Server/API/SessionsClient.swift`
- `OrbitDockNative/OrbitDock/Services/Server/Protocol/` types for plugin payloads
- a new native plugins UI surface under `OrbitDockNative/OrbitDock/Views/`

For Phase 2, add:

- `orbitdock-server/crates/server/src/connectors/subagent_parser.rs`
- `OrbitDockNative/OrbitDock/Views/SessionDetail/SessionWorkerRoster.swift`

## GH CLI Notes

This scope pass used `gh` against the upstream release and PRs, especially:

- `gh release view rust-v0.117.0 --repo openai/codex`
- `gh api repos/openai/codex/compare/rust-v0.116.0...rust-v0.117.0`
- `gh pr view 14988 --repo openai/codex`
- `gh pr view 14533 --repo openai/codex`
- `gh pr view 14847 --repo openai/codex`
- `gh pr view 14853 --repo openai/codex`
- `gh pr view 15041 --repo openai/codex`
- `gh pr view 15195 --repo openai/codex`
- `gh pr view 15215 --repo openai/codex`
- `gh pr view 15217 --repo openai/codex`
- `gh pr view 15264 --repo openai/codex`
- `gh pr view 15313 --repo openai/codex`
- `gh pr view 15342 --repo openai/codex`
- `gh pr view 15515 --repo openai/codex`
- `gh pr view 15556 --repo openai/codex`
- `gh pr view 15570 --repo openai/codex`
- `gh pr view 15606 --repo openai/codex`
- `gh pr view 15621 --repo openai/codex`
- `gh pr view 15713 --repo openai/codex`
- `gh pr view 15722 --repo openai/codex`
- `gh pr view 15820 --repo openai/codex`

That should make the next implementation pass straightforward.
