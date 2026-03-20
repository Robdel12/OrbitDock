# Web Frontend — Native Parity Plan

Living document tracking progress toward feature and design parity with the native macOS/iOS app.

---

## Phase 1: Composer & Footer Overhaul

The native composer is the richest single component in the app. The web version is functional but missing the status line, proper control grouping, mode indicators, and several controls.

### Native composer anatomy (top to bottom inside the bordered surface)

```
[Provider controls — permission/effort segmented control]
[Pending approval inline zone — permission/question/takeover]
[Text area]
[Toolbar — action buttons + send]
[Status bar — connection, permission pill, tokens, model, branch, cwd]
```

The web currently has provider controls + text area + toolbar. Missing: status bar, steer-mode indicator, follow/pin controls, model control, workflow overflow menu, and the status bar metadata strip.

- [x] **1.1 — Composer status bar**
  Add the metadata strip below the toolbar inside the composer surface border. Should contain (left to right): connection status pill (when disconnected), permission/autonomy pill (clickable, toggles provider controls), token usage label (color-coded: accent → orange at 70% → red at 90%), model name (monospaced), git branch (with icon, gitBranch color), working directory (folder icon, last path component). All in micro/caption type, tertiary/quaternary color.

- [x] **1.2 — Steer mode indicator**
  When `isWorking && text && !attachments`, show a thin strip above the composer surface: colored dot + "Steering Active Turn" label. Change send button icon from arrow-up to a return/uturn arrow. Ensure the placeholder text already says "Steer the agent..." (verify this).

- [x] **1.3 — Follow/pin controls in composer footer**
  Move the follow/scroll controls from SessionActionBar into the composer toolbar right side, next to the send button. Show: unread count badge (accent capsule) when scrolled up + follow/pause toggle (pin icon when following, pause icon when scrolled up). The SessionActionBar should keep the branch display but lose its scroll-to-bottom button.

- [x] **1.4 — Workflow overflow menu**
  Add an ellipsis (⋯) ghost button in the toolbar left side, after the existing controls + separator. Menu contains: Undo Last Turn, Fork Conversation, Compact Context (initial set — more items added in Phase 5).

- [x] **1.5 — Model/effort control button**
  Add a slider/tune icon ghost button in the toolbar left side (before image attach). Opens a popover with model selector (fetched from `/api/models/{provider}`) and effort picker for Codex. For Claude, shows model list only.

- [x] **1.6 — Replace toolbar icons with proper SVGs**
  The `/` command button SVG reads as "forbidden" (diagonal slash in circle). The `@` mention button looks like a file-with-plus. Replaced with clearer icons: `/` → terminal prompt chevron, `@` → at-sign circle.

- [x] **1.7 — Send button steer variant**
  When isWorking, change send button icon to a steer indicator. Match native's steer visual treatment.

---

## Phase 2: Dashboard Zone Layout

The native dashboard uses a priority-based zone system. The web has a flat list of identical cards. This is the biggest structural UX gap.

### Native dashboard zones

- **Attention** — largest cards, tinted background + solid edge bar, action description ("Wants to run Bash"), 2-line context
- **Working** — medium cards, 2-column grid on desktop, cyan border + edge bar, current activity
- **Ready** — compact single-line rows, minimal chrome, no edge bar

Each zone has a labeled header: icon + uppercase label + count capsule.

- [x] **2.1 — Zone-based session grouping**
  Replace flat SessionList with three zones: Attention (permission/question), Working (working status), Ready (reply/ended/waiting). Each zone gets a labeled header row. Sessions are sorted within zones by last_activity_at.

- [x] **2.2 — Attention card format**
  Largest card: status-colored tinted background + status-colored border + 3px solid left edge bar. Shows: status icon + action description (e.g. "Wants to run Bash", "Has a question") + model badge (right). Session name (bold) + dot-separated metadata (project/branch). 2-line context snippet.

- [x] **2.3 — Working card format**
  Medium card: backgroundSecondary fill + cyan border + cyan edge bar. Session name + model badge + recency. Project/branch metadata row. One-line context snippet. 2-column grid on desktop when >1 working session.

- [x] **2.4 — Ready/compact row format**
  Thin two-line row: status dot + name + inline metadata + model badge + recency. surfaceSelected on hover. No edge bar.

- [x] **2.5 — Dashboard status bar**
  Add a top bar above the filter toolbar: tab switcher (Active / Missions / Library capsule pills), connection badge, session count, action buttons (new session, search/⌘K, settings).

- [x] **2.6 — Replace native `<select>` with custom dropdowns**
  The filter toolbar uses browser-native `<select>` for sort and repo filter, clashing with the custom toggle buttons. Replace with styled dropdown menus matching the design system.

- [x] **2.7 — Empty state with CTA**
  Replace bare "No sessions yet" text with an illustration or icon + descriptive text + "New Session" CTA button.

---

## Phase 3: Session Header & Controls

The web header is functional but thinner than native. Missing model/effort badges, layout toggle, and proper intelligence zone.

- [x] **3.1 — Model + effort badges in header**
  After the session title, show a compact model badge (monospaced pill) and effort badge (when non-default). Match native's `UnifiedModelBadge` placement.

- [x] **3.2 — Layout toggle (segmented)**
  Add a segmented icon group for layout modes: conversation only, review split, (optionally) worker panel. Three small icon buttons in a shared container. Place in header trailing controls, before the pill actions.

- [x] **3.3 — Session header intelligence zone**
  Between title and actions, show contextual status pills: context % gauge (colored arc or bar), file changes count (when diff available). These duplicate information from the status strip but at a higher visual priority for at-a-glance scanning.

- [x] **3.4 — View mode toggle tooltip**
  Add a tooltip to the focused/verbose toggle icon button explaining what each mode does.

- [x] **3.5 — Overflow menu restructure**
  The overflow menu (mobile) should include: continuation actions (Fork, Fork to Worktree, Continue in New Session), context actions (Compact, Undo, Rollback), and destructive (End Session) — grouped by category with section dividers.

---

## Phase 4: Conversation View Polish

The conversation rendering works but is visually thinner than native. Missing status indicator, tool card inline previews, and some label consistency.

- [x] **4.1 — Conversation-bottom status indicator**
  Add an orbital status indicator strip at the bottom of the conversation timeline (above the action bar). Shows animated dot/beacon + status phrase: Working → rotating phrases + current tool name, Permission → "Awaiting clearance", Question → "Standing by", Reply → "Ready for next mission", Ended → "Mission Complete". Text colored by status.

- [x] **4.2 — "You" label on user messages**
  Add a "YOU" label above user message bubbles, matching the "ASSISTANT" label treatment (uppercase, caption, letter-spaced, muted accent color). Creates visual symmetry.

- [x] **4.3 — Tool card inline previews (collapsed state)**
  When collapsed, tool cards should show richer inline previews: diff strip (first line of diff in mono), live bash output indicator (pulsing green dot + last output line), todo progress (checklist + "N/M done" with micro progress bar).

- [x] **4.4 — Thinking row SVG chevrons**
  Replace text glyphs (▸/▾) with proper SVG chevron icons matching the design system.

- [x] **4.5 — Streaming dots animation**
  When assistant is streaming, show 3 animated dots (staggered bounce) as the streaming indicator, complementing the existing blinking cursor.

- [x] **4.6 — Unify scroll-to-bottom UX**
  The conversation has a "Jump to bottom" text link and the action bar has a "New ↓" pill — these serve the same purpose. Consolidate: use the floating pill from the action bar area, position it as an overlay at bottom-right of conversation (like native's `ConversationFollowPill`). Remove the text link.

---

## Phase 5: Session Lifecycle Features

Missing flows that native supports for session management.

- [x] **5.1 — Session resume**
  When a session is ended, show a resume row at the bottom of the conversation (or in the composer area, which already has a resume bar). Wire to `POST /api/sessions/{id}/resume`. On success, the session's WS events will resume.

- [x] **5.2 — Continue in new session**
  Add "Continue in New Session" to the workflow overflow menu and session header overflow. Opens the create session dialog pre-filled with context from the current session. Generates a bootstrap prompt summarizing the previous session's work.

- [x] **5.3 — Fork to worktree**
  Add "Fork to New Worktree" and "Fork to Existing Worktree" options. Fork to New: creates a worktree via `POST /api/worktrees` then forks the session into it. Fork to Existing: shows a worktree picker, then forks.

- [x] **5.4 — Real slash command dispatch**
  When the user selects a slash command from the completion menu, dispatch the actual action instead of inserting literal text. `/compact` → `onCompact()`, `/undo` → `onUndo()`, `/end` → `onEnd()`, etc. Only commands that are actually text prompts (like `/help`) should insert text.

- [x] **5.5 — Take over flow polish**
  Ensure the take-over bar renders cleanly when viewing a passive session. Match native's pulsing dot + "Take over to send messages" + "Take Over →" capsule button.

---

## Phase 6: Command Palette Full Feature Set

The shell is polished but functionality is shallow. Missing quick launch, inline rename, hover actions, and activity badges.

- [x] **6.1 — Quick launch mode**
  When user types "new claude" or "new codex", switch to quick launch mode showing recent projects. Selecting a project creates a session immediately.

- [x] **6.2 — Inline rename**
  Add Cmd+R / F2 shortcut while a session is selected in the palette to activate inline rename. Show a text input replacing the session name.

- [x] **6.3 — Hover-reveal action buttons**
  On session rows, reveal action buttons on hover: open in finder (copy path on web), rename, copy resume command, end session. Fade in with opacity + scale transition.

- [x] **6.4 — Activity badges on session rows**
  Show a colored capsule badge with current action text (e.g. "Running Bash", "Waiting for approval") on each session row.

- [x] **6.5 — Command mode completeness**
  Ensure `>` command mode covers all useful commands: New Claude/Codex Session, End Session, Compact Context, Fork, Settings, Missions, Worktrees.

---

## Phase 7: Visual Polish & Consistency

Systematic pass to replace rough edges and align with native design language.

- [x] **7.1 — Replace all text glyphs with SVGs**
  Audit all Unicode text glyphs used as icons (▸, ▾, ⑂, ✕, ›, ⌕, ···) and replace with proper SVG icons from lucide or custom paths.

- [x] **7.2 — Replace emoji file/folder icons**
  In mention completions, replace 📁/📄 emoji with proper SVG folder/file icons matching the design system.

- [x] **7.3 — Dashboard card hover microanimations**
  Add hover feedback to dashboard session cards: subtle background tint + slight elevation change. Match native's surfaceHover + Motion.hover pattern.

- [x] **7.4 — Component-level loading skeletons**
  Add skeleton loading states within components (session header, conversation rows, dashboard cards) not just page-level skeletons. Pulsing animation on backgroundTertiary rounded rects.

- [x] **7.5 — UsageSummary expand animation**
  Add smooth height transition to the usage summary collapse/expand (currently instant show/hide).

- [x] **7.6 — Prompt suggestion chips**
  When composer is empty and session is active (not working), show a horizontal row of prompt suggestion chips above the composer surface. Chips are tappable — tap sends the suggestion as a message.

---

## Phase 8: Settings & Remaining Pages

- [x] **8.1 — Settings sidebar navigation**
  Replace single-page scroll with sidebar-navigated panes: Connection, API Keys, Models, Usage, Preferences, Diagnostics. Use a 220px sidebar on desktop, tab chips on mobile.

- [x] **8.2 — Workspace preferences**
  Add workspace pane: default editor picker, session naming preferences.

- [x] **8.3 — Notifications settings**
  Add notifications pane: browser notification permission, sound selection (if applicable).

- [x] **8.4 — MCP elicitation UI**
  Handle MCP elicitation approval subtypes: URL auth flow (show URL, text input for code) and form-based elicitation (render form fields from server payload).

- [x] **8.5 — Shell mode**
  Add shell mode toggle (accessible from workflow overflow menu). When active, show a colored strip "Shell Command" above the composer, change input styling, send raw text as shell commands.

---

## Progress Tracker

| Phase | Items | Done | Status |
|-------|-------|------|--------|
| 1. Composer & Footer | 7 | 7 | Complete |
| 2. Dashboard Zones | 7 | 7 | Complete |
| 3. Session Header | 5 | 5 | Complete |
| 4. Conversation Polish | 6 | 6 | Complete |
| 5. Session Lifecycle | 5 | 5 | Complete |
| 6. Command Palette | 5 | 5 | Complete |
| 7. Visual Polish | 6 | 6 | Complete |
| 8. Settings & Pages | 5 | 5 | Complete |
| **Total** | **46** | **46** | Complete |
