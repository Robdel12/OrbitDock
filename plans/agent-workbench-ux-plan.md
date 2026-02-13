# OrbitDock Agent Workbench UX Plan (Fluid, Non-Modal)

> Goal: Make OrbitDock feel like the best place to build with LLM agents, without forcing people into rigid workflow modes.
>
> This plan is intentionally about fluid interaction design on top of the existing architecture. It complements `plans/roadmap.md` (feature parity and protocol/server work).

## Product Direction

OrbitDock is now more than a session viewer. It is a live developer workspace where planning, coding, approvals, steering, and review all happen together.

The key principle: **users should be able to bounce between these activities at any time**.
No hard gating. No "you are now in mode X, mode Y is unavailable."

### The Signature Difference: Live Collaborative Review

Every AI coding tool gives you a chat window. OrbitDock's differentiator is **live interactive review as the agent works** — not after-the-fact forensic review like GitHub PRs, but real-time annotation, feedback, and steering while changes are being produced.

This means the review surface is not a secondary feature — it is a **peer of the conversation canvas**. The core interaction loop is:

1. Watch the agent work (conversation canvas).
2. Review changes as they land (review canvas).
3. Annotate with precision feedback (line comments).
4. Steer the agent from review context (comment-to-steer).
5. Verify the agent addressed your feedback (review round-trip).

This loop is what makes OrbitDock the place you *want* to build from, not just a place you watch a terminal scroll.

## Design Principles

### 1) Fluid over rigid
- Treat planning, review, and approvals as capabilities that can appear contextually.
- Let users steer mid-turn, review diffs, and answer approvals in any order.

### 2) Conversation is important, but not sacred
- Keep conversation as a core thread.
- Allow adjacent high-signal surfaces (diffs, file-level review, approval queue) to take focus when needed.
- The review canvas should be able to take equal or greater screen real estate when the user is in a review-heavy flow.

### 3) Actionable context wins
- Surface "what needs attention now" first.
- Keep deep context one click away, never hidden behind complex navigation.

### 4) Keyboard-first flow
- Every critical action should be reachable quickly via command palette and shortcuts.
- Fast triage matters more than decorative UI.

### 5) Respect direct vs passive differences
- Be explicit about capabilities available in direct Codex sessions vs passive sessions.
- Do not present unavailable actions as primary controls.

### 6) Oversight-first, never opaque
- Do not abstract away agent behavior that matters for trust or review.
- Every summarized surface must link back to raw events, tool calls, and diffs.
- Compression is optional; inspectability is mandatory.

### 7) Review is live, not forensic
- Review happens *during* agent work, not after.
- Every change the agent produces should be reviewable the moment it lands.
- Feedback flows directly back to the agent as structured steering, not as a separate follow-up prompt.
- The review-to-steer loop should feel as tight as pair programming.

## SwiftUI Design Direction (Cohesive App Feel)

### Product tone
- Confident, technical, and calm under load.
- Feels like a serious coding cockpit, not a chat toy.
- Prioritize clarity and flow over visual novelty.

### Visual system direction
- Keep the existing OrbitDock dark system and cyan accent as identity anchors.
- Use semantic status colors aggressively for meaning, not decoration.
- Use one dominant accent in each surface, and reserve vivid highlights for user action and urgency.

### Layout direction
- Preserve the 3-zone shell:
  - Left: project/session navigation and cross-session awareness.
  - Center: conversation + turn timeline (primary narrative) OR review canvas (when review takes focus).
  - Right: capability rail (plan, approvals, skills, servers, attention strip).
- The center zone is **adaptive**: conversation-only, review-only, or split conversation+review.
- Let right-side capabilities appear as stackable sections with quick-switchable presets instead of hard "mode switches."
- Keep bottom input/action dock context-sensitive, but always visible and predictable.

### Signature interaction pattern
- Use "focus layers" rather than mode transitions:
  - Base layer: transcript/timeline.
  - Review layer: file/hunk navigation + line annotations (can take center zone or split with conversation).
  - Command layer: prompt/steer actions (always accessible from input dock and from review context).
- Users should be able to step in/out of each layer instantly without losing place.

### UX anti-goals
- No rigid wizard flow.
- No dead-end panels that force dismissals before continuing other work.
- No burying urgent actions (approvals/questions) behind hidden tabs.

## Experience Model (Capabilities, Not Modes)

Instead of fixed modes, OrbitDock should expose a **workspace with dynamic capability surfaces**:

- **Conversation Canvas**: the main timeline and agent narrative. Groups activity into scannable turns with expand/collapse for raw detail.
- **Review Canvas**: file tree, hunk navigation, line annotations, and "send notes to agent." A peer surface to conversation — not an overlay, not a sidebar panel. Can take the full center zone or share it with conversation in a split layout.
- **Capability Rail**: plan steps, MCP/tool context, skills, approval queue, attention strip. Stackable sections that can expand/collapse independently.
- **Action Dock**: prompt, steer, approve, fork, rollback, undo, compact. Always visible at the bottom. Context-aware: knows whether you're prompting, steering, or sending review feedback.

These coexist. The user decides what to focus on moment to moment.

## Composition Blueprint (End-State Layout)

This defines how all surfaces compose together when fully active. The goal is to verify that every capability has a home and that the layout holds under maximum load.

### Layout Configurations

**Default (conversation focus)**:
```
┌──────────┬──────────────────────────────┬──────────┐
│          │                              │ Plan     │
│  Agent   │     Conversation Canvas      │ ──────── │
│  List    │     (turn timeline view)     │ Approvals│
│  Panel   │                              │ ──────── │
│          │                              │ Skills   │
├──────────┼──────────────────────────────┼──────────┤
│          │  [Action Dock: prompt/steer]  │          │
└──────────┴──────────────────────────────┴──────────┘
```

**Review focus (review takes center)**:
```
┌──────────┬──────────────────────────────┬──────────┐
│          │      Review Canvas           │ Plan     │
│  Agent   │  ┌─────────┬──────────────┐  │ ──────── │
│  List    │  │ File    │  Diff view   │  │ Comments │
│  Panel   │  │ tree    │  + line      │  │ checklist│
│          │  │         │  annotations │  │ ──────── │
│          │  └─────────┴──────────────┘  │ Approvals│
├──────────┼──────────────────────────────┼──────────┤
│          │  [Action Dock: steer/review]  │          │
└──────────┴──────────────────────────────┴──────────┘
```

**Split (conversation + review side by side)**:
```
┌──────────┬──────────────┬───────────────┬──────────┐
│          │ Conversation  │ Review Canvas │ Plan     │
│  Agent   │ Canvas        │ ┌────┬──────┐ │ ──────── │
│  List    │ (compact      │ │Tree│ Diff │ │ Comments │
│  Panel   │  turns)       │ │    │      │ │ ──────── │
│          │               │ └────┴──────┘ │ Approvals│
├──────────┼──────────────┴───────────────┼──────────┤
│          │  [Action Dock: context-aware]  │          │
└──────────┴──────────────────────────────┴──────────┘
```

### Attention Strip

A persistent strip in the capability rail (or header) showing cross-session urgency:

```
┌─────────────────────────────────────────────────────┐
│ ● 2 approvals pending  ● 1 question waiting         │
└─────────────────────────────────────────────────────┘
```

This surfaces "needs me now" across all active sessions and is always visible regardless of which session is focused.

## Shared Interaction Primitives

Every phase must use these shared patterns to maintain cohesion. Define these before Phase 1 and reuse everywhere.

### 1) Collapsible Section
The building block for the capability rail. Each section has:
- **Header**: icon + label + count badge (when relevant) + collapse chevron.
- **Collapsed state**: header-only, ~32px height.
- **Expanded state**: content area with max-height constraint and internal scroll.
- **Keyboard**: Tab to cycle sections, Space/Enter to toggle.

### 2) Focus Zone
How the center zone transitions between conversation and review:
- **Transition**: animated split or swap, not a hard cut.
- **Trigger**: user clicks review action, keyboard shortcut, or auto-suggested when diffs land.
- **Return**: conversation position is preserved. Returning to conversation scrolls to where you left off.
- **Split resize**: draggable divider between conversation and review when in split mode.

### 3) Inline Action Card
Used for approvals, questions, and review comments that appear in conversation context:
- **Compact**: one-line summary with action buttons.
- **Expanded**: full context with risk cues, related turn link, and decision controls.
- **Keyboard**: arrow keys to navigate between cards, Enter to expand, shortcut keys for approve/deny.

### 4) Steer Context Indicator
How the action dock communicates current intent:
- **Visual**: accent-colored label strip above the input field showing current mode (`New Prompt`, `Steer Active Turn`, `Send Review Notes`).
- **Transition**: automatic based on session state (idle → prompt, working → steer, review focused → review notes). User can override.
- **Send behavior**: same keyboard shortcut (Enter/Cmd+Enter) but action varies by context. Always unambiguous.

## Surface-to-Color Mapping

New surfaces must slot into the existing theme hierarchy. This prevents ad-hoc color decisions during implementation.

| Surface | Background | Primary Accent | Status Color |
|---------|-----------|----------------|-------------|
| Conversation Canvas | `backgroundPrimary` | `accent` (cyan) | Per-message status |
| Review Canvas | `backgroundPrimary` | `accent` for navigation | — |
| Review: file tree | `backgroundSecondary` | `accent` for selected file | — |
| Review: diff hunks | `backgroundPrimary` | `accent` for added, `statusPermission` for removed | — |
| Review: line comments | `backgroundTertiary` | `statusQuestion` (purple) for comment markers | — |
| Capability Rail | `backgroundSecondary` | `accent` for active section | — |
| Attention Strip | `backgroundTertiary` | `statusPermission` (coral) for urgent | Status colors per event type |
| Approval cards | `panelBackground` | `statusPermission` (coral) | Decision state colors |
| Action Dock | `backgroundSecondary` | `accent` for send action | Mode indicator color |
| Turn containers | `backgroundSecondary` border | `accent` for active turn | Turn status (working/done/failed) |

### Rules
- Never introduce new colors outside the Theme.swift palette.
- Urgency uses `statusPermission` (coral). Information uses `accent` (cyan). User annotations use `statusQuestion` (purple).
- Background depth indicates hierarchy: `Primary` (deepest) for main content, `Secondary` for panels/containers, `Tertiary` for nested elements.

## Verbosity and Oversight Strategy

OrbitDock should handle high-volume agent output without hiding detail:

- Always keep a raw, chronological event stream available.
- Default to a turn-grouped view (`Detailed`) with expand/collapse for raw events per turn.
- Offer a `Turns` density that shows only turn summary chips for fast scanning.
- Both densities preserve full data — density is a presentation layer, not a data filter.
- Highlight "decision points" (approvals, steering, review comments, failures) in all densities.
- Preserve full provenance for reviews: which turn, which tool call, which file/line changed.
- Jump links: any summarized item links back to the raw source entries it represents.

## Feature Weaving (How It Feels End-to-End)

This is the core cohesion rule: each feature should be visible where it is needed, not where it was originally implemented.

- Plans should appear in turn context, not only in a dedicated panel.
- Diff/review should link directly to turns and tool actions that produced changes.
- Approvals should be triage-able globally, but resolvable in local context.
- Steering should be available from both input dock and contextual review surfaces.
- Review comments should be sendable as structured steer directly from the review canvas.
- Multi-agent work should feel like one project graph, not isolated chat windows.

## Scenario Playbooks

## Scenario A: Quick Bug Fix from a GitHub Issue (CLI-First, Single Agent Sprint)

### Typical intent
"I opened a GH issue and want this fixed quickly with confidence."

### UX flow
1. Open issue context from CLI workflow (for example `gh issue view`) and create/focus a direct session.
2. Agent runs a short exploration turn and proposes plan + patch.
3. Any tool approvals appear inline and in queue; user can approve without leaving context.
4. Review canvas opens on changed files as diffs land — user scans hunks in real time.
5. User adds line comments if needed and sends "apply these notes" as steer directly from review.
6. Agent updates code, reruns checks, and summarizes with PR-ready output.
7. User exits with commit/PR artifacts and linked issue status.

### UX emphasis
- Fast triage, minimal panel switching.
- Review canvas can take focus temporarily while conversation continues in background.
- High confidence "done" state includes tests, changed files, and linked issue.

## Scenario B: Linear Ticket Inside a Larger Project (Structured Delivery)

### Typical intent
"This ticket is one step in a bigger roadmap. I need traceable progress."

### UX flow
1. Launch session with ticket context and project-level constraints.
2. Plan cards stay visible throughout work; user can revise scope mid-turn.
3. Agent performs implementation in multiple turns with periodic check-ins.
4. Review canvas maps each change cluster back to ticket acceptance criteria.
5. User marks review comments and unresolved items; steer guides final pass.
6. Ticket output package is generated: summary, risks, tests, follow-ups.

### UX emphasis
- Persistent plan/criteria visibility.
- Better auditability across turns, not just "latest response wins."
- Easy handoff from implementation to review and back.

## Scenario C: 2-3 Agents on One Project (Parallel Workstreams)

### Typical intent
"Big enough task where I need parallel agents and I bounce between them constantly."

### UX flow
1. Start multiple sessions under one project workspace.
2. Left panel shows active workstreams with status and urgency.
3. Attention strip surfaces the next blocking event across all agents.
4. User hops via quick switcher; context rail remembers per-session focus state.
5. Review can compare diffs from different agents before merge decisions.
6. Steering can redirect one agent based on findings from another.
7. User closes loop with project-level completion view (what landed, what remains).

### UX emphasis
- Multi-agent awareness without overwhelming noise.
- Clear project-level heartbeat and blocking-event prioritization.
- Cross-agent learning loop (discover in one session, apply in another).

## Scenario D: Line-by-Line Doc Review and Feedback Pass

### Typical intent
"I want to annotate a plan/doc line by line and have the agent apply feedback precisely."

### UX flow
1. Open a document in review canvas with line numbers and paragraph blocks.
2. Add inline comments directly on lines/ranges with severity/tag (`clarity`, `scope`, `risk`, `copy`).
3. Review checklist in capability rail shows all open comments.
4. Send all or selected comments as a structured steer instruction bundle.
5. Agent updates the document and marks addressed comments with links to changed lines.
6. User performs a second pass, resolves remaining comments, and closes review.

### UX emphasis
- Precision feedback without losing global context.
- Strong mapping from comment to resulting change.
- Fast "annotate -> apply -> verify" loop.

## Core UX Opportunities

### 1) Turn-Oriented Timeline with Density Control
- Group transcript activity into turns with clear boundaries.
- Each turn shows: prompt, plan updates, tools run, resulting changes, and final output.
- Two density levels: `Detailed` (expand/collapse per turn) and `Turns` (summary chips only).
- Keep raw event granularity one click away at all times.

### 2) Approval Queue as First-Class Surface
- Keep inline approval cards in context.
- Add a queue view for batch triage across session (and eventually global).
- Provide safe, explicit decision language and risk cues.

### 3) Live Review Canvas with Line Annotations
- Full review surface that can take the center zone — not just a sidebar panel.
- File tree + hunk navigator with keyboard navigation.
- Inline line comments with tags/severity.
- Batch review comments into structured steer messages.
- Changes reviewable the moment they land, not after the turn ends.

### 4) Steering That Feels Intentional
- Make steering state obvious via the steer context indicator in the action dock.
- Three clear contexts: `New Prompt`, `Steer Active Turn`, `Send Review Notes`.
- Preserve steering history in the transcript so intent is inspectable.

### 5) Better Multi-Session Coordination
- Improve quick switcher and dashboard around "needs me now."
- Attention strip highlights cross-session urgent events (approval, question, failed action).
- Keep "return to where I was" friction near zero.

## Cross-Session UX Model (Project Lanes)

To support 2-3 agents per project, add lightweight project lanes:

- Lane header: project, branch family, key objective.
- Agent cards: current task, status, last meaningful event, pending asks.
- Shared queue: approvals/questions sorted by urgency and impact.
- Merge/review checkpoint: combined diff and risk summary before final integration.

This should remain optional and collapsible so solo flows stay fast.

## Actionable Delivery Phases (Roadmap Style)

Each phase is intentionally scoped as one completable task a developer, designer, or LLM can execute end-to-end.

Phases have been consolidated for tighter cohesion — related features ship together instead of accumulating incrementally.

Recommended execution sequence:
- `Phase 1 -> Phase 2 -> Phase 3 -> Phase 4 -> Phase 5 -> Phase 6`

## Phase Execution Template (Per Task)

Use this template for every phase ticket so work is self-contained:

Default file template:
- `plans/phase-ticket-template.md`

- **Designer output**: interaction flow, component states, and visual spec for the target surfaces.
- **Developer output**: implemented SwiftUI/state changes with instrumentation hooks where needed.
- **LLM output**: implementation checklist, test plan, and review notes mapped to acceptance criteria.
- **Validation**: demo script showing start-to-end behavior in at least one real scenario.

## Preflight Requirements (Before Starting Any Phase)

Treat this plan as directional, not absolute. Each implementer is expected to verify assumptions against the current codebase and product reality before building.

- [ ] Re-validate scope against current app state and in-flight changes.
- [ ] Research existing patterns in the target files and reuse before introducing new abstractions.
- [ ] Confirm dependencies and sequencing for the selected phase; adjust scope if dependencies have shifted.
- [ ] Document discovered deltas ("plan says X, code/product reality is Y") in the phase ticket.
- [ ] Re-state acceptance criteria in implementation terms before coding.
- [ ] Define a minimal test/verification plan (unit/integration/UI smoke) for the exact scope.
- [ ] Verify new surfaces use shared interaction primitives (collapsible section, focus zone, inline action card, steer context indicator).
- [ ] Verify new surfaces follow the surface-to-color mapping.

Preflight review questions:
- What has changed since this plan was written?
- What is the smallest shippable slice that still achieves the objective?
- What should be deferred to a follow-up phase to keep this task completable?

## Phase 1: Capability Rail + Action Dock Clarity

**Objective**: Replace tab-like rigidity with fluid capability sections. Make the action dock's intent explicit. Establish the shared interaction primitives used by all subsequent phases.

### Scope
- [ ] Define and implement shared interaction primitives: collapsible section, focus zone transition, inline action card, steer context indicator.
- [ ] Refactor right rail into stackable capability sections (replacing tab enum with independently collapsible sections).
- [ ] Add quick-switchable layout presets: "plan focused" (plan expanded, others collapsed), "review focused" (comments/changes expanded), "triage" (approvals prominent).
- [ ] Show capability badges in header (`Direct`, `Passive`, `Can Steer`, `Can Approve`).
- [ ] Add attention strip to capability rail or header showing cross-session urgency counts.
- [ ] Clarify input state with steer context indicator (`New Prompt` vs `Steer Active Turn`).
- [ ] Keep existing plan/diff/skills/servers functionality intact during refactor.

### Primary surfaces
- `CommandCenter/CommandCenter/Views/Codex/CodexTurnSidebar.swift`
- `CommandCenter/CommandCenter/Views/Codex/CodexInputBar.swift`
- `CommandCenter/CommandCenter/Views/SessionDetailView.swift`
- `CommandCenter/CommandCenter/Theme.swift`

### Definition of done
- [ ] User can access all capabilities without entering fixed modes.
- [ ] Urgent actions (approvals/questions) are visible without tab hunting.
- [ ] Attention strip shows pending approvals/questions across sessions.
- [ ] User always knows what action the send button will perform.
- [ ] Shared primitives are documented and reusable for subsequent phases.
- [ ] Existing keyboard shortcuts continue to work.

## Phase 2: Turn Timeline with Oversight

**Objective**: Make verbose activity scannable without removing detail. Guarantee raw inspectability.

### Scope
- [ ] Group transcript events into turn containers with clear boundaries.
- [ ] Show turn summary chips (plan progress, tools, changed files, status).
- [ ] Add expand/collapse for per-turn raw details (uses collapsible section primitive).
- [ ] Add density toggle: `Detailed` (default, expand/collapse per turn) and `Turns` (summary chips only).
- [ ] Add jump links from turn summaries back to raw tool events.
- [ ] Ensure no existing transcript data is hidden or dropped in any density level.

### Primary surfaces
- `CommandCenter/CommandCenter/Views/ConversationView.swift`
- `CommandCenter/CommandCenter/Views/SessionDetailView.swift`

### Definition of done
- [ ] User can scan 10+ turns quickly in `Turns` density.
- [ ] Raw event granularity is still one click away in all densities.
- [ ] Any summarized artifact can be traced to exact raw source entries.
- [ ] Rollback/fork actions remain discoverable at turn level.
- [ ] User can keep working entirely in detailed view if preferred.

## Phase 3: Live Review Canvas (File/Hunk Navigation + Line Annotations)

**Objective**: Build the signature review experience — a full review surface that is a peer of the conversation canvas, enabling real-time annotation and feedback as the agent works.

This is the core differentiator. The review canvas is not a sidebar panel or an afterthought. It is a first-class workspace surface that can take the center zone, share it with conversation in a split view, or expand to full focus.

### Scope
- [ ] Implement review canvas as a center-zone surface (not sidebar) with three layout modes: conversation-only, review-only, split.
- [ ] Add focus zone transitions: animated split/swap between conversation and review (uses focus zone primitive).
- [ ] File tree navigator with keyboard navigation (arrow keys, Enter to select, Escape to return to tree).
- [ ] Hunk-level navigation within files (n/p to jump between hunks).
- [ ] Inline line comment model: `ReviewComment` (file, line/range, body, status, tag, createdAt).
- [ ] Comment tags/severity: `clarity`, `scope`, `risk`, `nit`.
- [ ] Review checklist panel in capability rail showing open comments with filter for unresolved.
- [ ] Side-by-side relationship between turn and resulting file changes (jump from turn to exact changed file/hunk).
- [ ] Review canvas activates as diffs land — changes are reviewable immediately, not after the turn ends.

### Primary surfaces
- `CommandCenter/CommandCenter/Views/Codex/CodexDiffSidebar.swift` (evolves into review canvas)
- `CommandCenter/CommandCenter/Views/SessionDetailView.swift` (center zone layout management)
- `CommandCenter/CommandCenter/Views/ConversationView.swift` (split layout integration)
- `CommandCenter/CommandCenter/Services/Server/ServerAppState.swift` (review comment state)

### Likely new files
- `CommandCenter/CommandCenter/Views/Review/ReviewCanvas.swift`
- `CommandCenter/CommandCenter/Views/Review/FileTreeView.swift`
- `CommandCenter/CommandCenter/Views/Review/HunkNavigator.swift`
- `CommandCenter/CommandCenter/Views/Review/LineAnnotationView.swift`
- `CommandCenter/CommandCenter/Models/ReviewComment.swift`

### Definition of done
- [ ] User can review multi-file changes in a full-width review canvas, not just a sidebar.
- [ ] User can annotate line by line on active diffs with comment tags.
- [ ] User can jump from turn to exact changed file/hunk.
- [ ] Comments are persistent in session state and filterable (unresolved/all).
- [ ] Review canvas activates when diffs land without user needing to manually navigate.
- [ ] Conversation position is preserved when switching to/from review.
- [ ] Review flow works for both short and verbose diffs.
- [ ] Keyboard navigation covers: file selection, hunk jumping, comment placement, and return to conversation.

## Phase 4: Comment-to-Steer Bridge

**Objective**: Close the review loop — turn annotation feedback into actionable agent follow-up in one move.

### Scope
- [ ] Add `Send Review Notes` context to action dock steer context indicator.
- [ ] Add "Send selected comments as steer" action from review checklist.
- [ ] Add "Send all unresolved comments" bulk action.
- [ ] Serialize comments into deterministic steer payload format (file, line, tag, body).
- [ ] Add transcript markers linking steer payload to source comment IDs.
- [ ] After agent responds, review canvas marks which comments were addressed (links changed lines back to comment IDs).
- [ ] Follow-up review round: user can re-review, resolve addressed comments, add new ones, and send another round.

### Primary surfaces
- `CommandCenter/CommandCenter/Views/Codex/CodexInputBar.swift`
- `CommandCenter/CommandCenter/Views/Review/ReviewCanvas.swift`
- `CommandCenter/CommandCenter/Views/ConversationView.swift`
- `CommandCenter/CommandCenter/Services/Server/ServerAppState.swift`

### Definition of done
- [ ] User can choose all/some comments and send as steer in one action.
- [ ] Agent responses can be traced back to comment IDs/lines.
- [ ] Follow-up review shows which comments were addressed.
- [ ] The "annotate -> apply -> verify" loop completes in under 3 interactions.
- [ ] Review notes steer context is visually distinct from regular steering.

## Phase 5: Approval Oversight v2

**Objective**: Make approvals fast, contextual, and safe at high volume.

### Scope
- [ ] Add approval queue section in capability rail with filters (`pending`, `resolved`, `tool`, `session`).
- [ ] Improve inline action cards for approvals with clear decision labels/scopes (`once`, `session`, `always`, `abort`).
- [ ] Add risk cues to approval cards (command preview, affected files, tool type).
- [ ] Link approvals to related turn + changed files where possible.
- [ ] Keyboard shortcuts for rapid approval triage (approve/deny/skip without mouse).

### Primary surfaces
- `CommandCenter/CommandCenter/Views/Codex/CodexApprovalView.swift`
- `CommandCenter/CommandCenter/Views/Codex/CodexApprovalHistoryView.swift`
- `CommandCenter/CommandCenter/Views/SessionDetailView.swift`

### Definition of done
- [ ] User can process multiple approvals rapidly without context loss.
- [ ] Each approval has clear risk/scope semantics.
- [ ] Approval decisions remain auditable in history.
- [ ] Keyboard-only triage is possible for the full approval workflow.

## Phase 6: Multi-Agent Project Lanes

**Objective**: Support 2-3 concurrent agents on one project cleanly.

### Scope
- [ ] Add optional project lanes grouping active sessions by initiative.
- [ ] Add shared urgency strip for cross-agent blocking events (extends attention strip from Phase 1).
- [ ] Add quick switch stack to bounce across active workstreams.
- [ ] Review canvas supports comparing diffs from different agents.

### Primary surfaces
- `CommandCenter/CommandCenter/Views/DashboardView.swift`
- `CommandCenter/CommandCenter/Views/AgentListPanel.swift`
- `CommandCenter/CommandCenter/Views/QuickSwitcher.swift`

### Definition of done
- [ ] User can coordinate 2-3 agents on one project without losing track.
- [ ] Highest-priority blocking event is obvious at all times.
- [ ] Solo-agent workflows remain simple and not overloaded.

## Technical Mapping (Current Codebase)

Primary files/surfaces involved:
- `CommandCenter/CommandCenter/Views/SessionDetailView.swift`
- `CommandCenter/CommandCenter/Views/ConversationView.swift`
- `CommandCenter/CommandCenter/Views/Codex/CodexTurnSidebar.swift`
- `CommandCenter/CommandCenter/Views/Codex/CodexInputBar.swift`
- `CommandCenter/CommandCenter/Views/Codex/CodexApprovalView.swift`
- `CommandCenter/CommandCenter/Views/Codex/CodexApprovalHistoryView.swift`
- `CommandCenter/CommandCenter/Views/Codex/CodexDiffSidebar.swift`
- `CommandCenter/CommandCenter/Views/QuickSwitcher.swift`
- `CommandCenter/CommandCenter/Views/DashboardView.swift`
- `CommandCenter/CommandCenter/Services/Server/ServerAppState.swift`

Likely new models/state:
- `ReviewComment` (file, line/range, body, status, tag, author, createdAt)
- `TurnSummary` (turn id, prompt, tools, files, status, timestamps)
- `SessionCapabilityState` (derived capability flags by session type/status)
- `LayoutConfiguration` (conversation-only, review-only, split, and rail preset)
- `AttentionEvent` (cross-session urgency: pending approvals, questions, failures)

## Risks and Guardrails

- **Risk**: Over-complicating the UI with too many simultaneous panels.
  **Guardrail**: progressive disclosure, sane defaults, layout presets, and keyboard shortcuts.

- **Risk**: Turning fluid UX into accidental hidden modes.
  **Guardrail**: keep capabilities visible and accessible regardless of current focus. Attention strip ensures nothing is buried.

- **Risk**: Weak mapping between review notes and agent behavior.
  **Guardrail**: structured steer payloads with deterministic formatting. Comment-to-change traceability in transcript.

- **Risk**: Review canvas becoming a half-baked code review tool.
  **Guardrail**: the review canvas is live and collaborative, not forensic. It's fundamentally different from GitHub review — feedback flows to the agent immediately. Don't try to replicate GitHub's feature set; build for the live loop.

- **Risk**: 6 phases shipping incrementally cause visual/interaction drift.
  **Guardrail**: shared interaction primitives established in Phase 1. Surface-to-color mapping enforced at preflight. Every phase reuses the same card/section/zone patterns.

## Success Criteria

Qualitative:
- Users can pivot between planning, review, approvals, and steering without losing context.
- UI feels like a coding cockpit, not a chat wrapper.
- The review-to-steer loop feels like pair programming with the agent.
- Review canvas is the place users *want* to be during active work, not a chore after the fact.

Quantitative (post-instrumentation):
- Faster time-to-action for approvals and steering.
- Higher completion rate on review-driven follow-up turns.
- Lower context-switch friction across active sessions.
- Review comment-to-resolution cycle under 3 interactions.

## Near-Term Deliverables

- [ ] Phase 1: Capability Rail + Action Dock Clarity (shared primitives, fluid sections, attention strip, steer context).
- [ ] Phase 2: Turn Timeline with Oversight (density control, turn grouping, raw inspectability).
- [ ] Phase 3: Live Review Canvas (file/hunk navigation, line annotations, center-zone review surface).
- [ ] Phase 4: Comment-to-Steer Bridge (review feedback as structured agent steering).
- [ ] Phase 5: Approval Oversight v2 (fast contextual approvals with risk cues).
- [ ] Phase 6: Multi-Agent Project Lanes (project grouping, cross-agent attention, quick switching).
