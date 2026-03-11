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

## Recent Progress

We have moved a lot of the scary plumbing out of the critical path.

- worker lifecycle, persistence, and reload behavior are now real
- workers have a proper sidecar home and transcript linkage
- compact worker rows in the conversation can now focus the worker sidecar directly
- `request_permissions` is implemented end to end
- Codex control-plane settings are threaded through the server and app
- realtime handoff requests are now visible as intentional transcript artifacts instead of being dropped silently
- MCP/auth capability messaging is now present in the Codex capabilities UI

That means the roadmap is increasingly about cohesion and delight, not basic compatibility.

## Priority Order

1. Agent support
2. hooks, realtime transcript, and handoff visibility
3. apps and auth-aware MCP behavior
4. image generation and other polish

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

### UI Design Direction: Mission Control Clarity

The agent UI should feel like a mission control dashboard — clean hierarchy, purposeful color, information density that feels organized rather than overwhelming. Agents are first-class citizens, not hidden data.

Three surfaces for agent visibility:

#### Surface 1: Timeline Agent Orchestration Row (NEW)

When Codex spawns workers, inject a dedicated **Agent Orchestration Row** into the conversation timeline (new `TimelineRow` type). This replaces the scattered TaskCard approach with a unified view of all agents in a session turn.

- horizontal "agent strip" showing all active/spawned workers as colored pill avatars
- each pill: agent type icon + label + status dot (running/complete/failed)
- clicking a pill expands to show that worker's activity feed inline
- connected to the existing `focusWorkerInDeck` for companion panel deep dive
- requires changes to `ConversationTimelineProjector`, row factory, and a new cell type

```
┌─────────────────────────────────────────────────┐
│  ⚡ AGENTS DEPLOYED                    2 active │
│                                                 │
│  [🔭 Explorer ●]  [🗺 Planner ●]  [⚙ Worker ◉]│
│                                                 │
│  ▸ Explorer: Scanning src/ for auth patterns    │
│  ▸ Worker: Building OAuth integration    2m 14s │
└─────────────────────────────────────────────────┘
```

#### Surface 2: Enhanced TaskCard (refine existing)

The current `TaskCard.swift` works but can be elevated significantly:

- **Status ring animation** — pulsing ring for running, solid green stroke for complete, red for failed (replace static strokeBorder)
- **Agent avatar** — richer "agent badge" with provider logo overlay (Codex green dot / Claude cyan dot) on the agent type icon
- **Tool activity mini-timeline** — replace the flat list with a vertical timeline using connecting lines and visible time gaps between tool calls
- **Result card gradient** — the green "AGENT RESULT" section gets a left-edge gradient bar fading from agent color to green, more distinctive than the current flat background
- **Progressive disclosure** — collapsed shows agent label + status + one-line result preview; expanded shows full tool timeline + prompt + report

#### Surface 3: Companion Panel Redesign (refine existing)

The `SessionWorkerCompanionPanel` currently works but reads like a data dump. Redesign into a proper inspector:

- **Agent cards as tiles** — replace flat list rows with proper cards. Each worker gets: avatar, name, status badge, task preview, and a small sparkline-style activity indicator showing tool call density over time
- **Selected worker detail** — full-bleed within the panel:
  - **Header**: Large agent badge + name + status narrative
  - **Metrics strip**: Role | Provider | Model | Duration as horizontal badges (replace the `LazyVGrid` facts grid)
  - **Activity feed**: Tools rendered as a proper mini-timeline with the same tool colors from the main conversation (visual consistency)
  - **Report**: Markdown-rendered worker report using `MarkdownRepresentable` (currently plain text)
- **Parent-child relationships** — nested agents indent or connect visually with tree lines, not listed flat. Use `parentSubagentId` to build the hierarchy.

#### New Color Tokens

Extend `Theme.swift` with agent-specific colors:

```swift
// Agent type colors (consolidate with AgentTypeInfo)
static let agentExplorer = Color(red: 0.4, green: 0.7, blue: 0.95)    // Sky blue
static let agentPlanner = Color(red: 0.6, green: 0.5, blue: 0.9)      // Amethyst
static let agentWorker = Color(red: 0.85, green: 0.6, blue: 0.35)     // Warm amber
static let agentReviewer = Color(red: 0.45, green: 0.85, blue: 0.65)  // Seafoam
static let agentResearcher = Color(red: 0.75, green: 0.55, blue: 0.95) // Lavender
static let agentGeneral = Color(red: 0.5, green: 0.55, blue: 1.0)     // Soft indigo

// Agent orchestration surface
static let agentStripBg = Color.white.opacity(0.03)
static let agentConnectionLine = Color.white.opacity(0.12)
```

#### Implementation Phases

Phase 1 — Enhanced TaskCard (highest impact, least risk):
- status animations, agent badges, mini-timeline tool rendering
- files: `TaskCard.swift`, `Theme.swift`

Phase 2 — Companion Panel Redesign:
- tile-based worker cards, proper detail sections, markdown reports
- files: `SessionWorkerRoster.swift`, `SessionDetailView+Sections.swift`

Phase 3 — Timeline Agent Orchestration Row:
- new `TimelineRow` type, projector changes, new cell type
- files: `ConversationTimelineProjector.swift`, `ConversationCollectionTypes.swift`, row factory, new `AgentOrchestrationRow.swift`

### Best worker split

- Worker lane A: upstream Codex agent event and payload audit
- Worker lane B: Rust protocol and state model
- Worker lane C: Rust connector/runtime integration
- Worker lane D: Swift timeline and session UI (Phase 1 + Phase 3 agent rows)
- Worker lane E: companion panel and navigation UX (Phase 2 panel redesign)
- Worker lane F: tests and fixtures

## Completed: `request_permissions`

This is now done end to end.

OrbitDock can now:

- receive Codex `request_permissions`
- persist permission requests in approval history
- render them as a first-class approval UI in the composer
- grant requested permissions for one turn or the full session

That means the biggest remaining work is no longer the approval model. It is the rest of the Codex control plane and runtime visibility around agents, hooks, collaboration, and auth-aware capability behavior.

## Completed: Codex Control Plane

This is now in much better shape than it was when this roadmap started.

OrbitDock now has real end-to-end support for:

- `collaboration_mode`
- `multi_agent`
- `personality`
- `service_tier`
- durable `developer_instructions`

That support is threaded through the Rust server, persistence, Codex connector, session snapshots/deltas, and the Swift session configuration surfaces.

What still matters here is follow-through:

- verify the UX feels coherent in session creation and in-session controls
- separate autonomy from worker/agent behavior cleanly
- make sure takeover, resume, and passive-session paths behave consistently

So this is no longer the primary roadmap risk. It is now a stabilization and polish area.

## Epic 2: Hooks, Realtime Transcript, And Handoffs

These features are about visibility and trust.

Right now OrbitDock safely ignores a lot of latest Codex behavior. That keeps the upgrade stable, but it leaves users blind to meaningful runtime activity.

### What "good" looks like

- hook execution is visible when it matters
- transcript deltas are surfaced intentionally, not noisily
- handoff activity is understandable
- users can tell what Codex is doing without opening raw logs

### Current Status

- noisy realtime lifecycle bookkeeping is now suppressed instead of being dumped into the transcript
- realtime handoff requests are now surfaced as readable transcript events
- transcript deltas and raw conversation item churn are still intentionally hidden
- hook lifecycle visibility is still outstanding

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

## Epic 3: Apps And Auth-Aware MCP Behavior

This matters because latest Codex behaves differently depending on auth state, especially for apps.

That is a product behavior gap more than a transport bug.

### What "good" looks like

- OrbitDock reports available apps and MCP tools accurately
- users understand why a capability is missing
- ChatGPT-authenticated and API-key-authenticated behavior is tested and documented

### Current Status

- the MCP capabilities surface now explains the major ChatGPT-vs-API-key difference for Codex-backed app/MCP availability
- the remaining work here is mostly deeper capability surfacing and validation, not basic explanation

### Key files

- `orbitdock-server/crates/connector-codex/src/lib.rs`
- `orbitdock-server/crates/server/src/transport/http/capabilities.rs`
- `OrbitDockNative/OrbitDock/Views/Codex/McpServersTab.swift`
- `OrbitDockNative/OrbitDock/Views/Codex/SkillsTab.swift`

## Epic 4: Image Generation And Nice-To-Haves

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
- control-plane stabilization and verification

### Wave 2

- agent UI Phase 1: enhanced TaskCard with status animations, agent badges, mini-timeline
- agent UI Phase 2: companion panel redesign with tile cards and markdown reports
- hook and handoff visibility design

### Wave 2.5

- agent UI Phase 3: timeline agent orchestration row (new TimelineRow type)
- this is the most architecturally invasive UI change so it comes after the safer refinements land

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

The next strongest move is:

- deepen worker UX in the conversation and sidecar
- make hook/handoff/realtime behavior visible without transcript noise
- surface auth-aware apps/MCP availability clearly

That is now the shortest path to "OrbitDock feels like real Codex."
