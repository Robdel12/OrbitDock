# Codex Experience Parity Roadmap

This is the roadmap for making OrbitDock feel like modern Codex, not just compile against it.

We already finished the "latest works" upgrade to upstream `rust-v0.114.0`. That gets us a working baseline. It does not get us feature parity.

This doc is about what still matters for the actual Codex experience, in the order we should attack it.

## The Goal

Make OrbitDock great for the real Codex workflow:

- agent-heavy coding sessions
- modern approval flows
- richer session controls
- better visibility into what Codex is doing

Image generation is cool. It is not the priority right now.

The priority is the core coding experience.

## Priority Order

1. Agent support
2. personality and collaboration controls
3. hooks, realtime transcript, and handoff visibility
4. apps and auth-aware MCP behavior
5. image generation and other polish

## Epic 1: Agent Support

This is the top priority.

If OrbitDock is going to feel like current Codex, it needs to understand and present the experimental agent workflow properly. That means spawned agents, background work, status, results, failures, and the relationship between the parent session and the worker sessions.

### What "good" looks like

- you can see when Codex spawns agents
- you can tell which agent is doing what
- you can follow progress without reading raw JSON-like tool output
- you can inspect completed agent results
- parent and child work feels connected, not scattered
- agent activity is visible in the timeline and session state

### Likely OrbitDock touch points

- `orbitdock-server/crates/connector-codex/src/lib.rs`
- `orbitdock-server/crates/connector-codex/src/rollout_parser.rs`
- `orbitdock-server/crates/connector-core/src/event.rs`
- `orbitdock-server/crates/connector-core/src/transition.rs`
- `orbitdock-server/crates/server/src/domain/sessions/`
- `orbitdock-server/crates/server/src/runtime/`
- `OrbitDockNative/OrbitDock/Services/Server/`
- `OrbitDockNative/OrbitDock/Views/Conversation/`
- `OrbitDockNative/OrbitDock/Views/Codex/`

### Sub-epics

- Agent event inventory
  Map every upstream Codex event and tool result shape related to agents, workers, and delegated jobs.

- Server-side state model
  Add explicit runtime and persisted state for agent jobs, ownership, status, progress, and results.

- Timeline and session UX
  Design how parent-session activity and child-agent activity should render in the conversation and dashboard.

- Drill-in experience
  Add a way to inspect agent results without flooding the main timeline.

- Failure and retry semantics
  Decide how OrbitDock should present stuck, failed, interrupted, or cancelled agents.

### Best worker split

- Worker lane A: upstream Codex agent event and payload audit
- Worker lane B: Rust protocol and state model
- Worker lane C: Rust connector/runtime integration
- Worker lane D: Swift timeline and session UI
- Worker lane E: dashboard and navigation UX
- Worker lane F: tests and fixtures

## Completed: `request_permissions`

This is now done end to end.

OrbitDock can now:

- receive Codex `request_permissions`
- persist permission requests in approval history
- render them as a first-class approval UI in the composer
- grant requested permissions for one turn or the full session

That means the biggest remaining work is no longer the approval model. It is the rest of the Codex control plane and runtime visibility around agents, hooks, collaboration, and auth-aware capability behavior.

## Epic 2: Personality And Collaboration Controls

This is the next layer of "make OrbitDock feel like Codex."

OrbitDock already passes some collaboration settings through, but the control surface is still thin compared with current Codex behavior.

### What "good" looks like

- session setup exposes the right high-value Codex controls
- per-turn overrides are possible where they make sense
- collaboration and personality state are visible, not hidden
- the server remains the source of truth for these controls

### Key files

- `orbitdock-server/crates/connector-codex/src/lib.rs`
- `orbitdock-server/crates/server/src/transport/websocket/handlers/messaging.rs`
- `orbitdock-server/crates/server/src/runtime/message_dispatch.rs`
- `OrbitDockNative/OrbitDock/Services/Server/`
- `OrbitDockNative/OrbitDock/Views/Codex/`

### Best worker split

- Worker lane A: upstream capability audit
- Worker lane B: server/session model changes
- Worker lane C: request/override transport updates
- Worker lane D: session creation UI
- Worker lane E: per-turn controls UX

## Epic 3: Hooks, Realtime Transcript, And Handoffs

These features are about visibility and trust.

Right now OrbitDock safely ignores a lot of latest Codex behavior. That keeps the upgrade stable, but it leaves users blind to meaningful runtime activity.

### What "good" looks like

- hook execution is visible when it matters
- transcript deltas are surfaced intentionally, not noisily
- handoff activity is understandable
- users can tell what Codex is doing without opening raw logs

### Key files

- `orbitdock-server/crates/connector-codex/src/lib.rs`
- `orbitdock-server/crates/connector-codex/src/rollout_parser.rs`
- `orbitdock-server/crates/connector-core/src/transition.rs`
- `OrbitDockNative/OrbitDock/Views/Conversation/`

### Best worker split

- Worker lane A: hook event mapping
- Worker lane B: realtime transcript/handoff event mapping
- Worker lane C: state model and timeline event design
- Worker lane D: Swift rendering and UX polish

## Epic 4: Apps And Auth-Aware MCP Behavior

This matters because latest Codex behaves differently depending on auth state, especially for apps.

That is a product behavior gap more than a transport bug.

### What "good" looks like

- OrbitDock reports available apps and MCP tools accurately
- users understand why a capability is missing
- ChatGPT-authenticated and API-key-authenticated behavior is tested and documented

### Key files

- `orbitdock-server/crates/connector-codex/src/lib.rs`
- `orbitdock-server/crates/server/src/transport/http/capabilities.rs`
- `OrbitDockNative/OrbitDock/Views/Codex/McpServersTab.swift`
- `OrbitDockNative/OrbitDock/Views/Codex/SkillsTab.swift`

## Epic 5: Image Generation And Nice-To-Haves

This is real parity work, just not urgent for the current goal.

If we get here, the Codex experience is already in much better shape.

### What "good" looks like

- image generation events appear clearly
- results and saved paths are visible
- the UX feels intentional, not bolted on

## Suggested Execution Strategy

Do this in waves, not all at once.

### Wave 1

- agent support discovery and state model
- collaboration/personality and explicit experimental-agent config

### Wave 2

- agent UI
- collaboration/personality UI
- hook and handoff visibility design

### Wave 3

- hooks
- realtime transcript and handoff visibility
- apps/auth-aware behavior

### Wave 4

- image generation
- polish and cleanup

## How To Use The 40-Agent Budget Well

We can run a lot in parallel, but only if ownership is clear.

The safest pattern is:

- use explorers for short upstream/source audits
- use workers for bounded implementation slices
- keep write ownership disjoint
- never have multiple workers editing the same connector file at once unless one is explicitly following the other

### Good parallel split

- 4-6 agents on agent support
- 3-4 agents on collaboration/personality controls
- 3-4 agents on hooks/realtime/handoffs
- 2-3 agents on apps/auth behavior
- 1-2 agents on verification and fixture maintenance

That is enough to move fast without turning the branch into merge-conflict soup.

## Recommended Next Step

Start with a dedicated agent-support discovery sprint.

The fastest way to make good decisions here is to do one focused pass that answers:

- what exact upstream Codex events and tool outputs define the agent workflow
- what server-side state OrbitDock is missing
- what UI model gives users a clear mental model of parent work versus agent work

Right after that, start the `request_permissions` implementation in parallel.

That combination gets us closest to "OrbitDock feels like real Codex" the fastest.
