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

## What OrbitDock Is Not

OrbitDock is mission control for LLM agents. It is not an editor, not a terminal, not an IDE.

- **Not an editor.** Users have their own editors (emacs, vim, VS Code) with years of muscle memory and customization. OrbitDock shows diffs and accepts annotations — it does not provide editable code buffers or syntax-aware editing.
- **Not a terminal.** Users have their own terminals (iTerm, kitty, etc.). OrbitDock shows tool execution results and approval prompts — it does not provide a shell.
- **Not an IDE.** OrbitDock does not do file management, project scaffolding, build configuration, or debugging. Those belong to the user's existing tools.

OrbitDock's job is to **manage, oversee, and steer LLM agents** that work inside the user's existing development environment. Every feature should be evaluated against this boundary: "Does this help the user oversee and direct agent work, or are we rebuilding something that already exists in their workflow?"

The review canvas is a high-fidelity diff viewer with rich syntax highlighting, word-level diffs, and annotation capabilities — better rendering than GitHub's review UI, but not a code editor. You review what the agent produced, annotate your feedback, and the agent applies it in your actual codebase. When you want to touch code directly, "open in editor" takes you there. The value is in the live oversight loop: review, annotate, steer, verify.

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
- **Review Canvas**: high-fidelity diff viewer with syntax highlighting, word-level diff precision, file list, hunk navigation, line annotations, and "send notes to agent." A peer surface to conversation — not an overlay, not a sidebar panel. Can take the full center zone or share it with conversation in a split layout. Rendering quality should match or exceed GitHub's diff view, but the interaction model is fundamentally different: diffs stream in live, annotations flow back to the agent as steering, and the review-to-resolution loop is measured in seconds, not hours. Not an editor — users review and annotate, the agent applies changes. "Open in editor" bridges to the user's actual tools when they want to touch the code directly.
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
- High-fidelity diff viewer that can take the center zone — syntax highlighting, word-level diffs, unified/side-by-side toggle. Better than GitHub's review UI, not a watered-down version.
- File list + hunk navigator with keyboard navigation.
- Inline line comments with tags/severity for annotating feedback.
- Batch review comments into structured steer messages.
- Review activates when diffs land; live mid-turn streaming is a nice-to-have.
- "Open in editor" bridges to the user's actual tools. OrbitDock reviews; the editor edits.

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

## Server Architecture Dependencies

This plan depends on `plans/server-architecture-v2.md` (functional core, imperative shell refactor). The server v2 work is in progress and directly unblocks several UX features.

### What server v2 provides

| Server v2 Feature | UX Plan Dependency |
|---|---|
| `Input::TurnStarted` / `Input::TurnCompleted` as first-class state machine inputs | Turn timeline (Phase 2) — turn boundaries exist at the protocol level |
| Per-session actors with `SessionState` | Clean place to add turn history and per-turn diff snapshots |
| Revision-based event streaming + replay | Reliable delivery of turn lifecycle events to Swift UI |
| `EventPayload` enum with typed broadcasts | Swift side can consume structured events instead of parsing raw data |
| `ArcSwap<SessionSnapshot>` for lock-free reads | Attention strip can aggregate state across sessions without lock contention |

### Server-side additions (DONE)

All server changes needed for the workbench UX are implemented and tested:

- **Turn ID tracking** ✅: `current_turn_id` and `turn_count` on `TransitionState`, `SessionHandle`, `SessionState`. Turn IDs (`turn-{N}`) generated on `TurnStarted`, cleared on `TurnCompleted`/`TurnAborted`. Emitted via `SessionDelta` with `current_turn_id` and `turn_count` fields in `StateChanges`.
- **Per-turn diff snapshots** ✅: `TurnDiff { turn_id, diff }` struct. `turn_diffs: Vec<TurnDiff>` accumulates across turns. On `TurnCompleted`, `current_diff` is snapshotted into history and a `TurnDiffSnapshot` event is emitted. Full history included in `SessionState` snapshots.
- **Review comments** ✅: Migration `015_review_comments.sql`. `ReviewComment` type with tags (clarity/scope/risk/nit) and status (open/resolved). Full CRUD via WebSocket: `CreateReviewComment`, `UpdateReviewComment`, `DeleteReviewComment`, `ListReviewComments` → persisted to SQLite, broadcast to session subscribers.
- **Structured diff model**: Client-side parsing is fine for v1 — the server provides the raw unified diff string.

### What is purely client-side

All remaining work has no server dependency and can proceed independently:

- Swift-side `TurnSummary` model consuming the server's turn IDs (or synthetic boundaries for Claude sessions)
- `DiffModel` parser (parse the raw unified diff string into `[FileDiff]` with hunks)
- Swift-side `ReviewComment` model consuming the server's WebSocket CRUD
- Layout configuration state (`@AppStorage`)
- Input mode state machine
- All shared interaction primitives (SwiftUI components)

## Implementation Assumptions (Verified Against Codebase)

Assumptions verified by auditing the current codebase. Each gap is addressed in Phase 0.

| Assumption | Current Reality | Resolution |
|---|---|---|
| Turn IDs exist | ✅ Server now emits `current_turn_id` and `turn_count` via `SessionDelta`. `TurnDiffSnapshot` events provide per-turn diff history. | Phase 0: build Swift-side `TurnSummary` model consuming these server events. |
| Diff is a parsed model | Raw `String` in sidebar. BUT `EditCard` has a real LCS diff algorithm and `UnifiedDiffView` with line numbers + syntax highlighting. Aggregated diff string has `---/+++` file headers. | Phase 0: add `DiffModel` parser for file/hunk structure. Reuse existing LCS algorithm. Add word-level diff layer. |
| Syntax highlighting exists | Yes — `SyntaxHighlighter` with 12 languages via regex. Used in `EditCard` and `CodeBlockView`. NOT used in sidebar diff views. Separate `SyntaxColors` vs `Color.syntax*` in Theme.swift. | Phase 0: extract into own file, unify colors with Theme.swift. Apply to all diff surfaces. |
| Review comments can be stored | ✅ Server has `review_comments` table, full CRUD over WebSocket, broadcast to session subscribers. | Phase 0: build Swift-side model + WebSocket integration. |
| Layout supports dual center zones | Simple `HStack` with optional sidebar. No multi-zone flexibility. | Phase 0: add `LayoutConfiguration` state. Phase 3a implements the actual layout. |
| Input bar has a mode enum | Implicit `isSessionWorking` boolean. No manual override, no third mode. | Phase 0: add `InputMode` enum. |
| Cross-session attention aggregation | `AgentListPanel` groups by `needsAttention` (permission/question only). No review state, no global counts. | Phase 1: extend existing pattern with `AttentionEvent` aggregation. |
| Approval diffs are rendered | `ServerApprovalRequest.diff` field exists but is never shown in `CodexApprovalView`. | Phase 5: render approval diffs using existing `UnifiedDiffView`. |

## Actionable Delivery Phases (Roadmap Style)

Each phase is intentionally scoped as one completable task a developer, designer, or LLM can execute end-to-end.

Phases have been consolidated for tighter cohesion — related features ship together instead of accumulating incrementally.

Recommended execution sequence:
- `Phase 0 -> Phase 1 -> Phase 2 -> Phase 3a -> Phase 3b -> Phase 4 -> Phase 5 -> Phase 6`

Phase 0 is data infrastructure (invisible to the user, unblocks everything). Phase 3 is split into 3a (layout + diff navigation) and 3b (line annotations) because the combined scope is too large for a single phase.

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

## Phase 0: Data Infrastructure (Invisible, Unblocks Everything) — COMPLETE

**Objective**: Build the data models, state tracking, and parsing layers that all subsequent UI phases depend on. This phase produces no visible UI changes but is a hard prerequisite.

**Status**: ✅ Complete. All scope items implemented and building clean.

**Server dependency**: ✅ All server-side work is complete. The server now emits turn IDs with `TurnStarted`/`TurnCompleted`, snapshots diffs per-turn, and provides review comment CRUD over WebSocket. Phase 0 client work consumes these server features directly — no synthetic boundaries needed for Codex direct sessions. (Claude JSONL sessions still infer turn boundaries from message types.)

### Scope
- [x] **Turn tracking model**: `TurnSummary` struct (turn ID, start/end timestamps, messages, tools, changed files, status). Build a `TurnBuilder` that groups existing messages into turns. Codex direct sessions consume the server's `current_turn_id` and `turn_count` from `SessionDelta` events. Claude JSONL sessions infer turn boundaries from message types (a turn starts at a `human` message and ends at the next `human` message).
- [x] **Structured diff model**: `DiffModel` with `[FileDiff]` where each `FileDiff` has path, change type (add/modify/delete), hunks, and each hunk has line ranges + content lines. Parse from the aggregated unified diff string (`ServerAppState.getDiff()`) which already contains `---/+++` file headers. Add word-level diff highlighting: within changed line pairs (adjacent removal + addition), run character-level diff to produce `inlineChanges: [Range<String.Index>]` per line. Can reuse/extend the existing LCS algorithm from `EditCard.computeLCSDiff()`.
- [x] **Extract and unify SyntaxHighlighter**: Move `SyntaxHighlighter` from `MarkdownView.swift` (lines 470-1558) into its own file. Unify `SyntaxColors` enum with `Color.syntax*` in Theme.swift so all syntax highlighting uses the same color source.
- [x] **Review comment model (Swift side)**: `ReviewComment` Swift struct mirroring the server's type. CRUD operations via WebSocket (`CreateReviewComment`, `UpdateReviewComment`, `DeleteReviewComment`, `ListReviewComments`). Server-side table and persistence are already implemented.
- [x] **Layout configuration state**: `LayoutConfiguration` enum (conversationOnly, reviewOnly, split) + `RailPreset` enum (planFocused, reviewFocused, triage). Persisted per-session in UserDefaults or SQLite.
- [x] **Input mode state machine**: Replace `isSessionWorking` boolean in `CodexInputBar` with `InputMode` enum (`.prompt`, `.steer`, `.reviewNotes`). Auto-transitions: idle → prompt, working → steer. Manual override for reviewNotes.
- [x] **Attention aggregation**: `AttentionService` that observes all sessions and produces `[AttentionEvent]` (pending approvals, questions, unreviewed diffs). Extend the existing `needsAttention` pattern in `Session`.
- [x] **Component consolidation**: Unify the 5 model badge variants into one parameterized `ModelBadge` component with size enum. Extract `displayNameForModel()` / `colorForModel()` into a single `ModelStyle` utility. Consolidate duplicated tool icon mapping into `ToolCardStyle` as the single source of truth.
- [x] **Orphan cleanup**: Remove `ProjectArchiveSection`, `StatsSummary`, `SessionCard`, `CodexDiffSidebar`. Decide on `InboxView` and Quest system stubs (remove if no plans to rebuild; keep stubs if they'll become project lanes / attention features in Phase 6).

### Primary surfaces
- `CommandCenter/CommandCenter/Services/Server/ServerAppState.swift`
- `CommandCenter/CommandCenter/Views/Codex/CodexInputBar.swift`
- `CommandCenter/CommandCenter/Views/MarkdownView.swift` (extract SyntaxHighlighter)
- `CommandCenter/CommandCenter/Models/` (new files)
- Various views with duplicated model badge / tool icon code (consolidation)

### Likely new files
- `CommandCenter/CommandCenter/Models/TurnSummary.swift`
- `CommandCenter/CommandCenter/Models/DiffModel.swift`
- `CommandCenter/CommandCenter/Models/ReviewComment.swift`
- `CommandCenter/CommandCenter/Models/LayoutConfiguration.swift`
- `CommandCenter/CommandCenter/Views/SyntaxHighlighter.swift` (extracted from MarkdownView.swift)
- `CommandCenter/CommandCenter/Services/AttentionService.swift`

### Definition of done
- [x] `TurnBuilder` can group an existing conversation's messages into turns (handles human → tool_use → tool_result → assistant chains).
- [x] `DiffModel.parse(unifiedDiff:)` correctly splits a multi-file unified diff into `[FileDiff]` with hunks, using `---/+++` file headers.
- [x] Word-level diff highlighting produces `inlineChanges` ranges for changed line pairs.
- [x] `SyntaxHighlighter` is extracted into its own file; `SyntaxColors` and `Color.syntax*` in Theme.swift are unified.
- [x] `ReviewComment` can be created, read, updated, and deleted via WebSocket (server handles persistence).
- [x] `LayoutConfiguration` persists across session switches.
- [x] `InputMode` enum drives the input bar with correct auto-transitions.
- [x] `AttentionService` produces accurate counts of pending approvals/questions across sessions.
- [x] Model badge consolidated into one component with size variants; model name/color utilities in one place.
- [x] Tool icon/color mapping consolidated into `ToolCardStyle` as single source.
- [x] Orphaned views removed (ProjectArchiveSection, StatsSummary, SessionCard, CodexDiffSidebar).
- [ ] All models have basic unit tests.
- [x] No *new* visible UI changes — consolidation should be visually identical. Infrastructure only.

## Phase 1: Capability Rail + Action Dock Clarity — COMPLETE

**Objective**: Replace tab-like rigidity with fluid capability sections. Make the action dock's intent explicit. Establish the shared interaction primitives used by all subsequent phases.

**Status**: ✅ Complete. All scope items implemented and building clean.

### Scope
- [x] Define and implement shared interaction primitives: collapsible section, steer context indicator, capability badge, attention strip.
- [x] Refactor right rail into stackable capability sections (replacing tab enum with independently collapsible sections).
- [x] Add quick-switchable layout presets: "plan focused" (plan expanded, others collapsed), "review focused" (changes expanded), "triage" (all collapsed for scanning).
- [x] Show capability badges in header (`Direct`, `Passive`, `Can Steer`, `Can Approve`).
- [x] Add attention strip to capability rail showing cross-session urgency counts.
- [x] Clarify input state with steer context indicator (`New Prompt` vs `Steering Active Turn` vs `Review Notes`).
- [x] Keep existing plan/diff/skills/servers functionality intact during refactor.
- [x] Keyboard shortcuts: `Cmd+Option+1/2/3` for presets, `Cmd+Option+R` for rail toggle.
- [x] Fix server broadcast gap: `DiffUpdated` and `PlanUpdated` transitions now emit `SessionDelta` broadcasts (were previously persist-only, preventing live diff/plan data from reaching the Swift app).

### New files created
- `Views/Components/CollapsibleSection.swift` — Reusable disclosure section for the rail
- `Views/Components/SteerContextIndicator.swift` — Input mode strip above action dock
- `Views/Components/CapabilityBadge.swift` — Session capability capsule badges + `SessionCapability` enum
- `Views/Components/AttentionStripView.swift` — Cross-session urgency strip

### Key decisions
- **Sidebar is for operational context** (skills, MCP servers, approval queue, plan steps), not for deep content like diffs. The Changes section will become a compact summary linking to the full review canvas in Phase 3a.
- Keyboard shortcuts use `Cmd+Option` (not `Cmd+Shift`) to avoid macOS screenshot conflicts.
- Preset picker shows icon + text label for clarity.

### Primary surfaces
- `CommandCenter/CommandCenter/Views/Codex/CodexTurnSidebar.swift`
- `CommandCenter/CommandCenter/Views/Codex/CodexInputBar.swift`
- `CommandCenter/CommandCenter/Views/SessionDetailView.swift`
- `CommandCenter/CommandCenter/Views/HeaderView.swift`
- `orbitdock-server/crates/server/src/transition.rs`

### Definition of done
- [x] User can access all capabilities without entering fixed modes.
- [x] Urgent actions (approvals/questions) are visible without tab hunting.
- [x] Attention strip shows pending approvals/questions across sessions.
- [x] User always knows what action the send button will perform.
- [x] Shared primitives are reusable for subsequent phases.
- [x] Existing keyboard shortcuts continue to work.

## Phase 2: Turn Timeline with Oversight

**Objective**: Make verbose activity scannable without removing detail. Guarantee raw inspectability.

### Scope
- [ ] Group transcript events into turn containers with clear boundaries (uses `TurnSummary` from Phase 0).
- [ ] Show turn summary chips (plan progress, tools, changed files, status).
- [ ] Add expand/collapse for per-turn raw details (uses collapsible section primitive).
- [ ] Add density toggle: `Detailed` (default, expand/collapse per turn) and `Turns` (summary chips only).
- [ ] Add jump links from turn summaries back to raw tool events.
- [ ] Ensure no existing transcript data is hidden or dropped in any density level.
- [ ] Turn containers must be responsive at both full and compact widths (anticipating split layout in Phase 3a — conversation canvas may share the center zone with review canvas).

### Primary surfaces
- `CommandCenter/CommandCenter/Views/ConversationView.swift`
- `CommandCenter/CommandCenter/Views/SessionDetailView.swift`

### Definition of done
- [ ] User can scan 10+ turns quickly in `Turns` density.
- [ ] Raw event granularity is still one click away in all densities.
- [ ] Any summarized artifact can be traced to exact raw source entries.
- [ ] Rollback/fork actions remain discoverable at turn level.
- [ ] User can keep working entirely in detailed view if preferred.

## Phase 3a: Live Review Canvas (Layout + Diff Navigation + Magit Cursor) — COMPLETE

**Objective**: Build the review canvas as a first-class center-zone surface with magit-style cursor navigation. This is the structural foundation of the signature review experience.

**Status**: ✅ Complete. All core scope items implemented including magit-style cursor UX. Side-by-side view deferred to Phase 3a.1.

The review canvas is **read-only but high-fidelity** — not an editor, but a better review experience than GitHub. Rich syntax highlighting, word-level diff precision, fluid navigation, and live-streaming diffs as the agent works. If the user wants to edit a file directly, OrbitDock opens it in their preferred editor — we don't recreate that. But the review rendering itself should be best-in-class.

### Magit-style cursor model

The review canvas uses a **unified buffer** — one scrollable view showing ALL files and ALL diffs, with a non-editable cursor for keyboard-driven navigation. Like `magit-status` in Emacs.

**Cursor target types**: `CursorTarget` enum — `fileHeader`, `hunkHeader`, `diffLine`. `computeVisibleTargets()` builds a flat ordered list respecting collapsed files and hunks. Cursor movement is index arithmetic on this flat list.

**Keybindings**:
- `C-n` / `C-p` — line-by-line cursor movement (Emacs line nav)
- `C-f` / `C-b` — section jump (file headers + hunk headers)
- `n` / `p` — section jump (same as C-f/C-b)
- `TAB` — context-aware collapse (file header → collapse file, hunk header/line → collapse hunk)
- `RET` — open file at cursor in editor
- `q` — dismiss review pane
- `f` — toggle follow mode (auto-scroll to new files as they appear)

**Two-level collapse**: `collapsedFiles: Set<String>` for file sections, `collapsedHunks: Set<String>` for individual hunks. TAB differentiates based on cursor position. Collapse animates with spring, cursor snaps to the collapsed header.

**Focus management**: `@FocusState` + `.focused()` + `.onAppear { isCanvasFocused = true }`. Keyboard handlers use the proven `keyPress.key == "n"` + `.contains(.control)` pattern from `KeyboardNavigationModifier`.

### Building on existing infrastructure

The review canvas extends what already works — it does not start from scratch:
- **`EditCard` + `UnifiedDiffView`** already render syntax-highlighted diffs with dual line numbers, LCS diff computation, and green/red coloring. This is the rendering quality baseline.
- **`SyntaxHighlighter`** already supports 12 languages via regex. Extracted and unified in Phase 0.
- **`DiffModel`** (built in Phase 0) provides file-level and hunk-level structure with word-level inline changes.
- **`CodexDiffSidebar`** can be removed — its functionality is subsumed by the review canvas.

### Rendering quality bar
- **Syntax highlighting**: use the existing `SyntaxHighlighter` (12 languages, extracted in Phase 0). Diffs should look as good as code blocks in conversation messages, not like the current sidebar's plain text. TreeSitter is a future upgrade if regex coverage becomes limiting.
- **Word-level diff highlighting**: use `inlineChanges` from `DiffModel` (built in Phase 0) to highlight specific changed tokens within lines. This is what makes scanning large diffs fast.
- **Unified and side-by-side views**: user can toggle between unified diff (compact, good for small changes) and side-by-side (better for large refactors). Default to unified. Side-by-side only available in review-only layout mode (not split mode) to avoid screen real estate issues.
- **Collapsible unchanged regions**: large files with small changes should collapse unchanged sections with "show N hidden lines" expanders, like GitHub does.
- **Line numbers**: gutter with original and new line numbers for both sides (extend the existing dual line number pattern from `UnifiedDiffView`).
- **"Open in editor" action**: from any file in the review canvas, one action to open that file at the relevant line in the user's preferred editor. Uses the editor already configured in Settings > General (7 editors supported). No new configuration needed.
- **Nice-to-have: live diff streaming**: as the agent produces changes during a turn, the review canvas updates in real time — new files appear, hunks grow. Great if achievable, but the core value is the review-annotate-steer loop once diffs land, not mid-turn animation.

### Scope
- [x] Implement review canvas as a center-zone surface (not sidebar) using `LayoutConfiguration` from Phase 0. Three layout modes: conversation-only, review-only, split.
- [x] Replace the simple HStack in `SessionDetailView` with an adaptive layout manager that supports the three configurations.
- [x] Add focus zone transitions: animated split/swap between conversation and review (spring animation on layout switch).
- [x] Render diffs using `DiffModel` from Phase 0 — file-level grouping with expandable hunks, syntax highlighting via `SyntaxHighlighter.highlightLine()`, word-level diff highlighting within changed lines via `DiffModel.inlineChanges()`.
- [ ] Unified and side-by-side diff view toggle (deferred to Phase 3a.1 — complex synced scrolling for side-by-side).
- [x] Collapsible unchanged regions with "show N hidden lines" expanders (`ContextCollapseBar`).
- [x] Line number gutter with original and new line numbers (36pt fixed columns, monospaced 11pt, 35% opacity).
- [x] File list navigator: 220px left pane with changed files, change-type indicators (colored dots for added/modified/deleted), filename + parent path, +N/-N stats per file. Keyboard navigation (up/down arrows to navigate files).
- [x] Hunk-level navigation within files (n/p to jump between hunks via `ScrollViewReader`).
- [x] Historical per-turn diff viewing via source selector ("Live" vs per-turn entries from `obs.turnDiffs`).
- [x] Review canvas activates (suggests layout switch) when diffs are available — diff-available banner pill appears between header and conversation when diffs transition nil → non-nil. Auto-dismisses after 8s. Click → split layout.
- [x] Live diff streaming during active turns — diffs update live via `SessionObservable.diff` from server `SessionDelta` broadcasts.
- [x] "Open in editor" action: RET on any file opens in preferred editor. Reads `@AppStorage("preferredEditor")`.
- [x] Conversation scroll position preserved — `ConversationView` is its own component with independent scroll state, unaffected by layout switches.
- [x] Layout toggle in `HeaderView`: three-button segmented control (conversation-only, split, review-only) visible for Codex direct sessions only.
- [x] Keyboard shortcuts: Cmd+D toggles conversation <> split, Cmd+Shift+D → review-only, Escape returns from review/split to conversation-only.
- [x] Sidebar Changes section replaced with compact summary: file count + stats, max 5 filenames, "Open Review" button that triggers layout switch via callback.
- [x] `LayoutConfiguration` extended with `showsConversation`, `showsReview`, `label`, `icon` computed properties.
- [x] **Magit-style unified buffer**: all files and hunks in one scrollable view (replaced single-file selection model).
- [x] **Non-editable cursor**: `CursorTarget` enum with `computeVisibleTargets()` flat list. Three navigation granularities (line, section, file).
- [x] **Emacs keybindings**: C-n/C-p line nav, C-f/C-b section nav, n/p section nav. Uses proven `keyPress.key` + `.contains(.control)` pattern.
- [x] **Two-level collapse**: file-level and hunk-level independent collapse via TAB. Context-aware: TAB on file header collapses file, TAB on hunk header/line collapses hunk.
- [x] **Focus management**: `@FocusState` + `.focused()` + `.onAppear` for reliable keyboard event capture.
- [x] **Follow mode**: auto-scrolls to new files as they appear during active turns. Toggle with `f`.

### Deferred to follow-up
- **Side-by-side diff view** (Phase 3a.1): Complex synced scrolling between old/new panes. Unified view ships first.
- **Line annotations/comments** (Phase 3b): Inline comment markers, review checklist. Separate phase.
- **Draggable split divider**: Fixed 40/60 split for now. Draggable divider adds complexity without clear value until usage patterns emerge.

### New files created
- `Views/Review/ReviewCanvas.swift` — Magit-style unified buffer with cursor navigation, composing FileListNavigator + inline file/hunk sections
- `Views/Review/FileListNavigator.swift` — 220px left pane with diff source selector, stats summary, file list
- `Views/Review/FileListRow.swift` — Individual file entry with change-type dot, filename, stats
- `Views/Review/DiffFileView.swift` — Per-file hunk rendering (now orphaned — ReviewCanvas renders inline file sections directly)
- `Views/Review/DiffHunkView.swift` — Single `DiffHunk` with line numbers, prefix, syntax highlighting, word-level inline changes. Extended with cursor + collapse params.
- `Views/Review/ContextCollapseBar.swift` — Collapsible bar for hidden unchanged lines between hunks
- `Views/Review/ReviewEmptyState.swift` — Empty state messaging

### Modified files
- `Models/LayoutConfiguration.swift` — Added computed properties (`showsConversation`, `showsReview`, `label`, `icon`)
- `Views/SessionDetailView.swift` — Layout state, center zone switch, diff-available banner, keyboard shortcuts (Cmd+D, Cmd+Shift+D, Escape)
- `Views/HeaderView.swift` — Layout toggle segmented control, `layoutConfig` binding parameter
- `Views/Codex/CodexTurnSidebar.swift` — Changes section → compact summary with "Open Review" callback. Removed ~100 lines of old inline diff rendering (`CodexParsedDiffLine`, `DiffLineRow`)
- `Views/Review/DiffHunkView.swift` — Added `fileIndex`, `cursorLineIndex`, `isCursorOnHeader`, `isHunkCollapsed` params for cursor highlight + per-hunk collapse
- `Views/MenuBarView.swift` — Fixed pre-existing `.tertiary` Color type errors
- `Views/Usage/ProviderMenuBarSection.swift` — Fixed pre-existing `.tertiary` Color type error

### Key decisions
- **Unified diff only for v1**: Side-by-side synced scrolling is complex and deferred. Unified view with word-level inline highlights provides strong review quality.
- **Fixed 40/60 split**: No draggable divider — keeps implementation simple. Both panes use `maxWidth: .infinity` for equal flex.
- **Sidebar becomes compact summary**: The Changes section in `CodexTurnSidebar` now shows file count, stats, and max 5 filenames with an "Open Review" link. The full diff rendering lives in the review canvas center zone.
- **Reused `DiffModel.inlineChanges()` for word-level highlights**: Adjacent removed+added pairs get character-level LCS diff with accent color at 0.25 opacity behind changed ranges.
- **Magit-style over single-file selection**: The unified buffer with cursor navigation replaced the original "select a file from the strip, see its diff" model. No empty state when diffs exist — everything is visible immediately.
- **Flat cursor model**: `computeVisibleTargets()` produces a flat `[CursorTarget]` array. Cursor movement is simple index arithmetic. Collapse operations recompute the target list and snap the cursor.
- **Vertical-only scroll**: `ScrollView(.vertical)` instead of dual-axis. Horizontal scroll prevented `Spacer` from filling width and broke collapsed layout.

### Definition of done
- [x] User can review multi-file changes in a full-width review canvas, not just a sidebar.
- [x] Historical per-turn diff viewing via source selector.
- [x] Review canvas suggests activation when diffs land (banner pill).
- [x] Conversation position is preserved when switching to/from review.
- [x] Review flow works for both short and verbose diffs.
- [x] Magit-style cursor navigation: C-n/C-p for lines, n/p and C-f/C-b for sections, TAB for collapse, RET for open, q for dismiss, f for follow.
- [x] Layout transitions are animated and feel fluid, not jarring (spring response 0.35, damping 0.8).
- [x] All files and diffs visible immediately — no empty "select a file" state.

## Phase 3b: Line Annotations + Review Checklist — COMPLETE

**Objective**: Add the annotation layer on top of the review canvas — inline line comments, review checklist, and the feedback infrastructure that Phase 4 will connect to steering.

**Status**: ✅ Complete. All scope items implemented across commits `637eece` and `bf71703`.

### Scope
- [x] Inline line comment UI: `CommentComposerView.swift` — `c` key to compose, C-space for range mark, mouse drag on gutter for range selection.
- [x] Comment tags/severity: `clarity`, `scope`, `risk`, `nit` — selectable when composing a comment.
- [x] Comment markers: `InlineCommentThread.swift` + `ResolvedCommentMarker.swift` with purple accent markers on annotated lines.
- [x] Review checklist section in capability rail (`ReviewChecklistSection.swift`) showing open comments with filter (unresolved/all) and selection toggles.
- [x] Comment navigation: `]`/`[` keys to jump between unresolved comments in the review canvas; click comment in checklist to navigate.
- [x] Keyboard: `c` to add comment, `]`/`[` to cycle, `r` to resolve, `x` to toggle selection, `Shift+X` to clear selection.
- [x] Comment resolution: `r` key to toggle resolve manually. Auto-resolution on send in Phase 4.
- [x] Turn-scoped comments: comments attach to specific edit turns via `turnId`.
- [x] Design tokens: `Spacing`, `TypeScale`, `Radius`, `OpacityTier` + diff color palette (`diffAddedBg`, `diffRemovedBg`, etc.) added to Theme.swift.

### New files created
- `Views/Review/CommentComposerView.swift` — Inline comment composer with tag picker
- `Views/Review/InlineCommentThread.swift` — Renders open comments below annotated diff lines with selection toggle
- `Views/Review/ResolvedCommentMarker.swift` — Grouped resolved comment markers with expand
- `Views/Review/ReviewChecklistSection.swift` — Capability rail section with filter, selection, and send button
- `Views/Review/CodeReviewFeedbackCard.swift` — Rich card for sent review feedback in conversation

### Definition of done
- [x] User can annotate line by line on active diffs with comment tags.
- [x] Comments are persistent in session state (SQLite via server WebSocket CRUD) and filterable (unresolved/all).
- [x] Comment checklist in capability rail shows open comments with jump-to-line.
- [x] Keyboard navigation covers comment placement and cycling through unresolved comments.
- [x] Comment markers are visually distinct (purple accent) and don't interfere with diff readability.

## Phase 4: Comment-to-Steer Bridge — COMPLETE

**Objective**: Close the review loop — turn annotation feedback into actionable agent follow-up in one move.

**Status**: ✅ Complete. Core review-annotate-steer-verify loop fully working across commits `bf71703` and `5b72726`.

### Scope
- [x] Add `Send Review Notes` context to action dock steer context indicator. `InputMode.reviewNotes` with `SteerContextIndicator` visual.
- [x] Add "Send selected comments as steer" action from review checklist. `x` key toggles selection on individual comments, `Shift+X` clears selection. Send bar and checklist reflect selection count.
- [x] Add "Send all unresolved comments" bulk action. `Shift+S` sends all open if none selected, or sends only selected.
- [x] Serialize comments into deterministic steer payload format (file, line, tag, body + actual diff content). `formatReviewMessage()` produces structured markdown with code blocks.
- [x] Add transcript markers linking steer payload to source comment IDs. `<!-- review-comment-ids: id1,id2,... -->` embedded as HTML comment footer in the review message.
- [x] After agent responds, review canvas highlights which files changed since comments were written — review banner shows "X of Y reviewed files updated". `ReviewRound` struct tracks `turnDiffCountAtSend` to detect post-review changes.
- [x] Follow-up review round: user can re-review, resolve addressed comments, add new ones, and send another round. Comments auto-resolve on send; new comments can be added immediately.
- [x] `CodeReviewFeedbackCard` renders sent review feedback as a rich card in conversation with file sections, syntax-highlighted code blocks, tag badges, and jump-to-diff navigation.

### New files created
- `Views/Review/CodeReviewFeedbackCard.swift` — Rich conversation card for sent review feedback

### Key decisions
- **Selection is opt-in**: By default `Shift+S` sends all open comments. Selection via `x` key enables partial sends without adding mandatory UI ceremony.
- **HTML comment for IDs**: Comment IDs are embedded as `<!-- review-comment-ids: ... -->` — invisible to the model but parseable from stored transcript messages for traceability.
- **Shared selection state**: `selectedCommentIds` is owned by `SessionDetailView` and passed as bindings to both `ReviewCanvas` and `CodexTurnSidebar` so selection syncs between the review canvas and the sidebar checklist.

### Definition of done
- [x] User can choose all/some comments and send as steer in one action.
- [x] Agent responses can be traced back to comment IDs/lines.
- [x] Follow-up review shows which comments were addressed.
- [x] The "annotate -> apply -> verify" loop completes in under 3 interactions.
- [x] Review notes steer context is visually distinct from regular steering.

## Phase 5: Approval Oversight v2

**Objective**: Make approvals keyboard-first with diff previews and risk awareness. The approval card already works — this phase makes it fast, contextual, and safe when approvals come frequently.

### What already exists
- `CodexApprovalView` — inline card above input bar with Approve/Deny/Session/Always/Abort buttons
- `CodexApprovalHistoryView` — session/global history with decision labels and delete
- `ServerApprovalRequest.diff` field — populated from the Rust server but **never rendered**
- `AttentionService` + attention strip — cross-session pending approval counts
- Tool badge with `ToolCardStyle.icon(for:)` — already shown on approval card
- `DiffModel` parser + `DiffHunkView` rendering — full syntax-highlighted diff infrastructure from review canvas

### Scope
- [ ] **Diff preview on patch approvals**: When `ServerApprovalRequest.diff` is non-nil (Edit/Write tools), render it inline in the approval card using `DiffModel.parse()` + `DiffHunkView`. Collapsible, expanded by default for small diffs (<30 lines), collapsed for large ones.
- [ ] **Risk cues**: Color-code the approval card header by risk level. `Shell`/`Bash` with destructive patterns (rm, git push --force, DROP, etc.) get `statusPermission` (coral) accent. Edit/Write get a neutral accent. Unknown tools get a caution accent. Show affected file count for patch approvals.
- [ ] **Keyboard-first triage**: When an approval is pending, bind `y` (approve once), `Y` (approve for session), `!` (always allow), `n` (deny), `N` (deny & stop/abort). Keys only active when approval card is visible. Show key hints on the buttons.
- [ ] **Approval card redesign**: Rebuild `CodexApprovalView` using the design token system (`Spacing`, `TypeScale`, `Radius`, `OpacityTier`) and the proven card patterns from the review canvas. Current card uses hardcoded `.padding(16)` / `.clipShape(RoundedRectangle(cornerRadius: 12))` etc.
- [ ] **Approval history in rail**: Move `CodexApprovalHistoryView` into a collapsible section in the capability rail (alongside Plan, Comments, etc.) instead of the current inline toggle below the input bar. Filter by pending/resolved/tool type.

### Primary surfaces
- `CommandCenter/CommandCenter/Views/Codex/CodexApprovalView.swift` (redesign)
- `CommandCenter/CommandCenter/Views/Codex/CodexApprovalHistoryView.swift` (move to rail)
- `CommandCenter/CommandCenter/Views/Codex/CodexInputBar.swift` (keyboard bindings, remove inline history toggle)
- `CommandCenter/CommandCenter/Views/Codex/CodexTurnSidebar.swift` (add approval history section)

### Definition of done
- [ ] Patch approvals show syntax-highlighted diff preview inline.
- [ ] Dangerous commands are visually distinct from routine approvals.
- [ ] User can approve/deny entirely via keyboard without touching the mouse.
- [ ] Key hints visible on approval buttons so keybindings are discoverable.
- [ ] Approval history accessible from the capability rail with filters.

## Technical Mapping (Current Codebase)

### Existing diff and syntax highlighting infrastructure

The codebase already has significant diff rendering and syntax highlighting. The review canvas builds on this foundation — it does not start from scratch.

**`EditCard` + `UnifiedDiffView`** (`Views/ToolCards/EditCard.swift`):
- Custom LCS diff algorithm (`computeLCSDiff`) — computes Longest Common Subsequence between old/new string arrays. This is a real diff algorithm, not just line-prefix parsing.
- Dual line numbers (old + new columns, like GitHub).
- Syntax highlighting on every diff line via `SyntaxHighlighter.highlightLine()`.
- Green addition / red deletion backgrounds with bright accent text.
- Expand/collapse for diffs over 25 lines, stats header (+N/-N).
- Handles Claude Edit tool (old_string/new_string), Write tool (full content), and Codex fileChange (unified diff parsing).
- **This is the rendering quality baseline for the review canvas.**

**`SyntaxHighlighter`** (`Views/MarkdownView.swift`, lines 470-1558):
- Custom regex-based highlighter, no third-party dependencies.
- 12 languages: Swift, JavaScript/TypeScript, Python, JSON, Bash, YAML, SQL, Go, Rust, HTML/XML, CSS, plus generic fallback.
- Keyword, type, string, comment, number pattern detection via `NSRegularExpression`.
- Own `SyntaxColors` enum (separate from `Color.syntax*` in Theme.swift — needs unification).
- **Good enough for v1. TreeSitter is a future upgrade, not a blocker.**

**`CodeBlockView`** (`Views/MarkdownView.swift`):
- Language badge with colored dot, language normalization (js→javascript, etc.).
- Line numbers, copy to clipboard, expand/collapse for blocks over 15 lines.
- Syntax highlighting via `SyntaxHighlighter`.

**Aggregated turn diff** (`ServerAppState.sessionDiffs`):
- Unified diff string per session, populated from Rust server via WebSocket.
- Contains `---/+++` file headers for multi-file diffs — parseable into file-level structure.

### Existing but disconnected / underused

- **`CodexDiffSidebar`** — standalone diff component, NOT wired into any view. Can be removed or cannibalized.
- **`CodexTurnSidebar` Changes tab** — renders aggregated diff but with NO syntax highlighting (plain text + line-prefix coloring). Should be upgraded to use `SyntaxHighlighter` and eventually replaced by review canvas link.
- **`ServerApprovalRequest.diff`** — field decoded from Rust server but never rendered in `CodexApprovalView`. Phase 5 should render this.
- **`SyntaxColors` enum vs `Color.syntax*` in Theme.swift** — duplicated color systems for syntax highlighting. Phase 0 should unify these.

### What needs to be built

- **File-level diff grouping**: parse the aggregated unified diff string (which has `---/+++` file headers) into `[FileDiff]` structs. The string format is well-defined.
- **Word-level (intra-line) diff highlighting**: within changed line pairs, highlight the specific tokens that changed. Extend `computeLCSDiff` or add a character-level pass.
- **File list navigation**: flat list of changed files extracted from the parsed diff, with change-type indicators and jump-to-file.
- **Side-by-side diff view**: render old and new side by side (in addition to existing unified view). Only available in review-only layout mode to avoid screen real estate issues.
- **Review canvas layout**: center-zone surface that hosts the file list + diff view, using the `LayoutConfiguration` state.
- **Line annotation layer**: comment markers on diff lines, comment composer, review checklist.
- **Comment-to-steer bridge**: serialize annotations into steering payloads.

### Component quality assessment

**Already polished — preserve and extend, don't rewrite:**
- Theme.swift design system (700 lines, comprehensive tokens, status system, effects)
- ConversationView message rendering (all message types, images, thinking, tool cards)
- MarkdownView + SyntaxHighlighter (production-quality markdown, 12-language highlighting)
- Tool cards (16 distinct types via `ToolIndicator` router, consistent `ToolCardContainer` pattern)
- QuickSwitcher / command palette (1129 lines, search, keyboard nav, inline actions)
- Toast notification system (ToastManager + ToastView)
- KeyboardNavigationModifier (arrow keys + Emacs bindings, used by QuickSwitcher + DashboardView)
- CodexInputBar (rich input: model/effort pickers, $skill and @mention completion, image attachments)
- CodexApprovalView / CodexQuestionView (5 decision options, question flow)
- CommandBar (rich stats: cost, tokens, cache savings, model distribution, rate limit gauges)
- DashboardView (active sessions, session history with date/project grouping, command bar)
- HeaderView (breadcrumb, status dot with orbit glow, model badge, editor picker via @AppStorage)
- SettingsView (4 tabs: General with editor picker, Notifications, Setup, Debug)
- Usage system (multi-provider: Claude 5h/7d windows, Codex primary/secondary, projection bars)

**Needs consolidation (component duplication):**
- **Model badges**: 5 separate implementations (`ModelBadge`, `ModelBadgeMini`, `ModelBadgeCompact`, `CompactModelBadge`, inline in MenuBarSessionRow) all with copy-pasted model name normalization. Should be one parameterized component with size variants.
- **Model name/color utilities**: `displayNameForModel()` and `colorForModel()` duplicated across HeaderView, AgentRowCompact, CommandBar, SessionRowView, SessionCard. Should be a single `ModelStyle` enum or extension.
- **Tool icon mapping**: Duplicated in `ActiveSessionRow`, `QuickSwitcher`, `CodexApprovalView`, `ToolCardStyle`, `ToolIndicator`, `ActivityBanner`. Should be a single `ToolStyle` source of truth.
- **CompactStatusBadge legacy shim**: Creates fake `Session` objects just to bridge APIs. Should use `SessionDisplayStatus` directly.

**Orphaned / disabled views to clean up:**
- `ProjectArchiveSection` — superseded by `SessionHistorySection` (which has its own project grouping toggle). DashboardView doesn't use it.
- `StatsSummary` — superseded by `CommandBar`'s integrated stats display.
- `SessionCard` — grid-style card using the old 3-state status system. Dashboard uses `ActiveSessionRow` (list layout) now.
- `CodexDiffSidebar` — superseded by `CodexTurnSidebar` Changes tab. Will be fully replaced by review canvas.
- `InboxView` — disabled stub ("temporarily unavailable"). Decide: remove or rebuild as part of attention strip / project lanes.
- `QuestListView`, `QuestDetailView`, `QuestRow` + `Quest.swift`, `QuestLink.swift` models — disabled stubs. Decide: remove or rebuild as part of project management features.

**Existing feature: editor picker in Settings.** `SettingsView` General tab already has an editor picker (VS Code, Cursor, Zed, Sublime, Emacs, Vim, Neovim) stored in `@AppStorage`. Phase 3a's "open in editor" action should use this — no need to build a new configuration system.

### Reuse strategy for Phase 3a

The review canvas should **extend** `UnifiedDiffView`'s rendering approach, not replace it:
1. Extract `SyntaxHighlighter` into its own file and unify colors with Theme.swift.
2. Build `DiffModel` parser that splits the aggregated diff string into `[FileDiff]` (using the existing `---/+++` file header format).
3. Reuse the existing LCS diff computation for per-file rendering.
4. Add word-level highlighting as a layer on top of existing line-level highlighting.
5. Wrap the per-file diff rendering in a new `ReviewCanvas` that adds file navigation, layout management, and annotation support.

### Primary files/surfaces involved

- `CommandCenter/CommandCenter/Views/SessionDetailView.swift`
- `CommandCenter/CommandCenter/Views/ConversationView.swift`
- `CommandCenter/CommandCenter/Views/ToolCards/EditCard.swift` (existing diff rendering to reuse)
- `CommandCenter/CommandCenter/Views/MarkdownView.swift` (existing SyntaxHighlighter to extract)
- `CommandCenter/CommandCenter/Views/Codex/CodexTurnSidebar.swift`
- `CommandCenter/CommandCenter/Views/Codex/CodexInputBar.swift`
- `CommandCenter/CommandCenter/Views/Codex/CodexApprovalView.swift`
- `CommandCenter/CommandCenter/Views/Codex/CodexApprovalHistoryView.swift`
- `CommandCenter/CommandCenter/Views/Codex/CodexDiffSidebar.swift` (likely removed, replaced by review canvas)
- `CommandCenter/CommandCenter/Views/QuickSwitcher.swift`
- `CommandCenter/CommandCenter/Views/DashboardView.swift`
- `CommandCenter/CommandCenter/Services/Server/ServerAppState.swift`

### Likely new models/state

- `ReviewComment` (file, line/range, body, status, tag, author, createdAt)
- `TurnSummary` (turn id, prompt, tools, files, status, timestamps)
- `DiffModel` / `FileDiff` / `DiffHunk` (structured parsing of aggregated unified diff)
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

- **Risk**: Review canvas drifting toward an editor.
  **Guardrail**: the review canvas should have best-in-class rendering (syntax highlighting, word-level diffs, side-by-side view) but zero editing capabilities. The quality bar is *higher* than GitHub's diff view — but the interaction boundary is clear: review and annotate, don't edit. If you're tempted to add "edit this line directly," stop — use "open in editor" to bridge to the user's actual tools. The value is in the live oversight-and-steer loop, not in becoming another code editor.

- **Risk**: Scope creep toward IDE/terminal features.
  **Guardrail**: evaluate every feature against the product boundary: "Does this help oversee and direct agent work, or are we rebuilding something that already exists in the user's editor/terminal?" OrbitDock manages agents, it does not replace dev tools.

- **Risk**: 8 phases shipping incrementally cause visual/interaction drift.
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

- [x] Phase 0: Data Infrastructure (turn tracking, diff parsing, review comments, layout state, input mode, attention aggregation).
- [x] Phase 1: Capability Rail + Action Dock Clarity (shared primitives, fluid sections, attention strip, steer context, server broadcast fix).
- [ ] Phase 2: Turn Timeline with Oversight (density control, turn grouping, raw inspectability).
- [x] Phase 3a: Live Review Canvas + Magit Cursor (unified buffer, cursor navigation, two-level collapse, Emacs keybindings, layout system, syntax-highlighted diffs with word-level inline changes).
- [x] Phase 3b: Line Annotations + Review Checklist (inline comments, tags, turn-scoped comments, design tokens, review checklist in rail).
- [x] Phase 4: Comment-to-Steer Bridge (selective sends, transcript traceability, review round tracking, rich feedback cards).
- [ ] Phase 5: Approval Oversight v2 (diff previews, risk cues, keyboard-first triage, design token alignment).
