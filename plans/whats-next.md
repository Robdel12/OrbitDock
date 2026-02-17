# What's Next

> Consolidated from the feature parity roadmap and UX plan after a big weekend push.
> Previous plans archived in `plans/completed/`.
>
> Everything below is genuinely open work — no status markers to maintain, no completed phases to scroll past.

---

## 1. Turn Timeline with Oversight

**Why**: The conversation view shows every message flat. With 10+ turns in a session it's a wall of text. You lose the forest for the trees.

**What**: Group messages into collapsible turn containers so you can scan activity at a glance without losing raw detail.

- Group transcript events into turn containers using `TurnSummary` (built in Phase 0, consumes server's `current_turn_id` / `turn_count`)
- Show turn summary chips: prompt snippet, tools run, files changed, token cost, status
- Expand/collapse per turn — default expanded for the active turn, collapsed for older turns
- Density toggle: `Detailed` (expand/collapse) and `Turns` (summary chips only)
- Jump links from turn summaries back to raw tool events
- Turn containers responsive at both full and compact widths (split layout with review canvas)
- No data hidden in any density — raw events always one click away

**Primary files**: `ConversationView.swift`, `TurnGroupView.swift`, `SessionDetailView.swift`

**Done when**:
- Can scan 10+ turns quickly in `Turns` density
- Raw event granularity is still one click away
- Rollback/fork actions remain discoverable at turn boundaries
- Works in both conversation-only and split layouts

---

## 2. Review Mode (codex-core Op::Review)

**Why**: Ask the agent to review code — uncommitted changes, a branch diff, a specific commit. Currently you'd have to type out the instructions manually. codex-core has a dedicated `Op::Review` for this.

**What**: Wire up the review operation end-to-end so you can trigger a structured code review from the UI.

### codex-core events
| Op | EventMsg |
|----|----------|
| `Op::Review { review_request }` | `EnteredReviewMode(ReviewRequest)` |
| *(turn completes)* | `ExitedReviewMode(ReviewOutputEvent)` |

### Review targets
- `UncommittedChanges` — working tree (staged, unstaged, untracked)
- `BaseBranch { branch }` — compare current branch to base
- `Commit { sha, title? }` — review specific commit
- `Custom { instructions }` — free-form review prompt

### Implementation path
1. **Protocol** (`crates/protocol`): `ClientMessage::StartReview`, `ServerMessage::ReviewStarted` + `ReviewCompleted`, `ReviewTarget` enum
2. **Connector** (`crates/connectors`): `start_review()` → `Op::Review`, handle `EnteredReviewMode` / `ExitedReviewMode`
3. **Server** (`crates/server`): `CodexAction::StartReview`, websocket handler, broadcast events
4. **Swift**: Protocol types, `ServerAppState.startReview()`, UI trigger (review canvas or action bar)
5. **Tests**: Protocol roundtrips, event sequence test
6. **MCP bridge**: `POST /api/sessions/:id/review`

**Done when**:
- Can trigger a review of uncommitted changes from the UI
- Review results appear in conversation and feed into the review canvas
- All 4 review target types work

---

## 3. Custom Prompts, Elicitation, and Stream Errors

Three smaller features that improve daily quality of life. Can be shipped independently.

### 3a. Custom Prompts

**Why**: Codex supports project-defined prompt templates (`Op::ListCustomPrompts`). Surface them so users can pick from their project's prompts instead of typing from scratch.

- `ClientMessage::ListCustomPrompts { session_id }`
- `ServerMessage::CustomPromptsList { session_id, prompts }`
- Connector: `list_custom_prompts()` → `Op::ListCustomPrompts`
- Swift: prompt picker in input bar (similar to skills picker)

### 3b. Elicitation

**Why**: Sometimes the agent needs structured input — multiple choice, text fields, confirmation. codex-core has `EventMsg::ElicitationRequest` for this. Currently these would just hang with no UI.

- `ClientMessage::ResolveElicitation { session_id, server_name, request_id, decision }`
- `ServerMessage::ElicitationRequested { session_id, request_id, ... }`
- Connector: handle `EventMsg::ElicitationRequest`, send `Op::ResolveElicitation`
- Swift: inline form card in conversation (similar to approval/question cards)

### 3c. Stream Errors

**Why**: When the model stream fails or warns, the user sees nothing. Surface these so failures aren't silent.

- `ServerMessage::StreamError { session_id, message, details }`
- `ServerMessage::Warning { session_id, message }`
- Connector: handle `EventMsg::StreamError` + `EventMsg::Warning`
- Swift: error/warning banners in conversation

**Done when**:
- Custom prompts are browsable and selectable
- Elicitation requests render as interactive forms
- Stream errors and warnings are visible in the UI

---

## Backlog (nice-to-have, no timeline)

These came up during previous phases but aren't blocking anything:

- **Side-by-side diff view** — synced scrolling between old/new panes in review canvas
- **MCP bridge endpoints** — HTTP routes for skills, context ops, MCP tools (server support exists)
- **Remote skills download UI** — server support done, needs SwiftUI view
- **Unit tests for Phase 0 models** — TurnSummary, DiffModel, ReviewComment parsers
- **Draggable split divider** — review/conversation split is fixed 40/60 ratio currently

---

## Implementation Pattern

Every feature follows this path:

```
Protocol (crates/protocol)  →  types + roundtrip tests
Connector (crates/connectors)  →  action + event handler
Server (crates/server)  →  session action + websocket handler + broadcast
Swift app  →  protocol types + ServerAppState + view
MCP bridge  →  HTTP endpoint (optional)
```

Build from the bottom up — protocol types first, UI last.
