# Web Frontend Parity Roadmap

> Goal: Bring the OrbitDock web frontend to full feature parity with the macOS SwiftUI app.
>
> Constraint: Pure JS (Preact + Signals). No TypeScript. Server-authoritative — the web client renders, it doesn't reason about state.
>
> Principle: **Mobile-first**. All new UI must work on 375px viewports. Build responsive, then enhance for desktop.
>
> Approach: Ship in phases. Each phase is independently useful and testable. Earlier phases unlock later ones. Within each phase, items can be tackled in any order.

---

## Current State

The web frontend covers the core loop: session list, conversation view with all 12 row types, server-driven tool cards, approval flow with version gating, message composer, WebSocket sync, and basic missions/settings pages.

Everything below is what the macOS app has that the web doesn't.

---

## Phase 1: Session Actions + Composer Upgrades ✅

The most impactful day-to-day improvements. Fills in missing session controls and makes the composer usable for real work.

### Session Actions

- [x] **Rename session** — click-to-edit in header, `PATCH /api/sessions/{id}/name`
- [x] **Fork session** — popover with optional nth_user_message, `POST /api/sessions/{id}/fork`
- [x] **Takeover session** — button for passive sessions, `POST /api/sessions/{id}/takeover`
- [x] **Rollback turns** — popover with turn count, `POST /api/sessions/{id}/rollback`
- [x] **Steer turn** — inline input in header, `POST /api/sessions/{id}/steer`
- [x] **Resume session** — replaces composer when ended, `POST /api/sessions/{id}/resume`

### Composer Improvements

- [x] **Image attachments** — paste, drag-drop, file input with thumbnail previews
- [x] **Rate limit banner** — countdown banner from `rate_limit_event` WS message
- [x] **Provider-specific controls** — Codex effort picker, Claude permission policy picker
- [x] **Pending message indicator** — pulsing dot while message is in flight

### Approval Enhancements

- [x] **Approval diff preview** — inline diff rendering for `patch` type approvals
- [x] **Permission detail popover** — expandable permission list with edge-bar treatment
- [x] **Exec enhancement** — cwd display, improved code block formatting

---

## Phase 1.5: Responsive / Mobile-First Layout ✅

The web frontend has zero `@media` queries and a 260px non-collapsible sidebar that eats 70% of a phone screen. This must be fixed before shipping anything else — every feature we build inherits whatever layout system we have.

### Critical Fixes

- [x] **Collapsible sidebar** — hamburger toggle, hidden by default on mobile (<768px), visible on desktop. Overlay mode on mobile (slides over content), push mode on desktop.
- [x] **Breakpoint system** — add CSS custom properties or media query mixins for `sm` (< 640px), `md` (640–1024px), `lg` (> 1024px)
- [x] **Remove overflow:hidden clipping chain** — `body`, `.shell`, `.main` all clip; replace with proper overflow management so mobile doesn't silently eat content
- [x] **Session header responsive** — wrap action buttons into a dropdown/menu on narrow viewports instead of a non-wrapping flex row of 7 buttons
- [x] **Steer input** — remove `min-width: 240px`, let it flex to available width
- [x] **Rename input** — remove `min-width: 180px`, let it flex
- [x] **Action popovers** — viewport-aware positioning on mobile (center or bottom-sheet instead of absolute right-anchored)
- [x] **Settings grid** — responsive columns that reflow to single-column on mobile

### Session List (Mobile)

- [x] **Full-width session list** — when sidebar is collapsed, session list becomes the main view (not crammed into a 260px sidebar)
- [x] **Tap to open** — session tap navigates to session detail; back button returns to list
- [ ] **Pull-to-refresh** — optional touch gesture to refresh session list

### Composer (Mobile)

- [x] **Touch-friendly** — larger tap targets for buttons (minimum 44px)
- [ ] **Keyboard avoidance** — ensure composer stays visible above the virtual keyboard on iOS/Android
- [ ] **Simplified actions** — collapse attach/stop/send into a more compact layout on narrow widths

### General

- [x] **Safe area insets** — respect `env(safe-area-inset-*)` for notched/dynamic island devices
- [ ] **Touch scrolling** — ensure `-webkit-overflow-scrolling: touch` and proper scroll behavior on iOS
- [ ] **Font scaling** — use `rem` or `em` where possible so user font size preferences are respected
- [x] **Viewport height** — use `dvh` (dynamic viewport height) instead of `100vh` to account for mobile browser chrome

### Complete when

- App is fully usable on a 375px phone screen
- Sidebar collapses to an overlay on mobile
- All interactive elements meet 44px minimum touch target
- No content is silently clipped by overflow:hidden

---

## Phase 2: Dashboard + Session List Upgrades ✅

Bring the dashboard from a basic grouped list to a proper command center.

### Dashboard

- [ ] **Activity stream layout** — card-based session activity view (alternative to current flat list)
- [x] **Filter controls** — filter by provider, project/repo, work status
- [x] **Sort controls** — sort by last activity, name, status
- [x] **Usage gauges** — visual gauge bars for Claude and Codex usage with rate-limit windows (replace raw JSON)

### Session Detail

- [x] **Worker/subagent roster panel** — dedicated panel showing parallel sub-agents with status
- [x] **Session detail action bar** — scroll-to-bottom with unread count badge, branch/path info
- [x] **Diff available banner** — banner when a turn diff is ready to review
- [x] **Worktree cleanup banner** — banner for completed worktree sessions
- [x] **Contextual status strip** — inline context indicators (model, tokens, etc.)

### Complete when

- Dashboard has filter/sort controls and usage gauges
- Session detail shows worker roster and contextual banners

---

## Phase 3: Quick Switcher / Command Palette ✅

Keyboard-first navigation for power users. Big productivity unlock.

- [x] **Command palette overlay** — `Cmd+K` / `Ctrl+K` trigger
- [x] **Fuzzy session search** — search across session names, prompts, repos
- [x] **Command mode** — `>` prefix for commands (end session, compact, new session, etc.)
- [x] **Quick-launch shortcuts** — `new claude` / `new codex` with recent project list
- [x] **Keyboard navigation** — arrow keys, Enter to select, Escape to dismiss
- [ ] **Preview panel** — show session preview on hover/selection

### Complete when

- `Cmd+K` opens a command palette with session search and command execution
- All major actions are accessible via command palette

---

## Phase 4: Settings + Configuration ✅

Make settings actually useful instead of read-only diagnostics.

### Settings Pages

- [x] **General preferences** — configurable settings (theme, behavior)
- [x] **API key management** — set/update OpenAI key, Linear key with validation feedback
- [ ] **Notification preferences** — per-event toggles and channel selectors (when notification system lands)
- [ ] **Editor preferences** — font size, line numbers, word wrap for code views
- [x] **Connection diagnostics** — endpoint health, latency, reconnection controls
- [x] **Debug/diagnostics panel** — server info, version, build info, log viewer

### Complete when

- Users can manage API keys and preferences from the web UI
- Settings are writable, not just read-only

---

## Phase 5: Worktree Management ✅

Full worktree lifecycle from the web.

- [x] **Worktree list page** — list worktrees grouped by repo, show health status
- [x] **Create worktree dialog** — repo path, branch name, base branch inputs
- [x] **Complete/cleanup worktree** — complete action with branch cleanup options
- [x] **Worktree badges** — badge on sessions that are running in worktrees
- [x] **Discover worktrees** — trigger worktree discovery for a repo

### Complete when

- Full worktree CRUD from the web UI
- Sessions show worktree context

---

## Phase 6: Review Canvas ✅

The biggest single feature. Magit-style code review integrated into the session view.

### Core Review

- [x] **Split layout** — conversation + review canvas side by side (layout toggle)
- [x] **Unified diff view** — file-level diffs with syntax highlighting
- [x] **File list navigator** — sidebar listing changed files with status icons
- [x] **Hunk navigation** — keyboard shortcuts to jump between hunks (]/[)
- [x] **File navigation** — keyboard shortcuts to jump between files via file navigator

### Comments + Review Flow

- [x] **Inline comment threads** — click on diff line to add comment
- [x] **Comment composer** — textarea with Cmd+Enter submit
- [ ] **Review rounds** — round-based workflow tracking
- [ ] **Send comments to model** — batch selected comments and send as review feedback
- [ ] **Resolved comment markers** — mark comments as resolved
- [x] **Context collapse** — collapse unchanged sections with expand on click

### Complete when

- Users can review diffs, leave inline comments, and send review feedback to the model
- Keyboard-driven navigation through files and hunks

---

## Phase 7: Mission Control Depth ✅

Bring missions from basic list+detail to full management.

### Mission Management

- [x] **Tabbed detail view** — Overview, Issues, Settings tabs
- [x] **Mission settings editor** — edit all MISSION.md sections (provider, trigger, orchestration, prompt, tracker)
- [ ] **New mission flow** — guided setup for creating a new mission
- [x] **Active thread display** — live view of running agent threads per mission
- [x] **Command center** — aggregated mission status with quick actions
- [x] **API key banner** — prompt to configure Linear API key when missing
- [x] **Provider selection** — primary/secondary provider selection with strategy picker

### Complete when

- Full mission CRUD and settings editing from web
- Live thread monitoring
- API key setup flow

---

## Phase 8: Toast Notifications ✅

Non-intrusive attention system for multi-session awareness.

- [x] **Toast container** — fixed-position toast stack (bottom-right or top-right)
- [x] **Session attention toasts** — fire when another session needs permission/question/reply
- [x] **Auto-dismiss** — configurable timeout (default 5s)
- [x] **Max visible** — cap at 3 visible toasts
- [x] **Click to navigate** — clicking a toast navigates to that session
- [x] **Suppress for focused session** — don't toast for the session you're already viewing
- [ ] **Sound** — optional notification sound (browser Notification API or audio)

### Complete when

- Users get alerted when sessions they're not viewing need attention
- Toasts are non-intrusive and navigable

---

## Phase 9: Skills, MCP, and Capabilities ✅

Per-session capabilities UI.

- [x] **Skills tab** — list available skills for a session
- [x] **Skills picker** — enable/disable skills per session
- [x] **MCP servers tab** — list MCP server tools available to a session
- [x] **MCP status indicators** — show server health, auth status per MCP server

### Complete when

- Users can see and manage skills and MCP tools per session

---

## Phase 10: Polish + Progressive Enhancement ✅

Final pass for production quality.

- [x] **`@mention` file completions** — autocomplete file paths in composer with `@` trigger
- [x] **Slash command completions** — `/command` autocomplete in composer
- [ ] **Library/archive view** — browse historical sessions grouped by project
- ~~**Responsive layout**~~ — promoted to Phase 1.5
- [x] **Keyboard shortcut help** — `?` overlay showing all available shortcuts
- [x] **Loading skeletons** — skeleton UI for all async-loaded views
- [x] **Error boundaries** — graceful error states for component failures
- [x] **Offline indicator** — clear indicator when disconnected with retry controls
- [x] **Favicon/title updates** — show unread count or attention state in browser tab

### Complete when

- Web frontend is polished, responsive, and handles all edge cases gracefully
- Composer has full autocomplete support

---

## Sequencing Notes

1. **Phase 1 is done.**
2. **Phase 1.5 (responsive) is next** — every subsequent feature inherits the layout system, so this must land before we build more UI. Mobile-first means we fix the foundation.
3. **Phases 2-3 can run in parallel** — dashboard upgrades and command palette are independent.
4. **Phase 4 can start anytime** — settings is self-contained.
5. **Phase 5 depends on Phase 2** (worktree badges appear in session detail).
6. **Phase 6 is the largest phase** — can be split into sub-phases (core diff view first, then comments, then review rounds).
7. **Phase 7 can start after Phase 1** — missions don't depend on other phases.
8. **Phase 8 can start anytime** — independent notification system.
9. **Phases 9-10 are polish** — tackle after core features are solid.
10. **All new components must be mobile-first** — design for 375px, enhance for wider.

## API Coverage

All REST endpoints in SPEC.md are already wired in the API layer (`src/api/rest/`). Most missing features are UI-only — the plumbing exists, the surface doesn't.

Endpoints that may need new API client work:
- `POST /api/sessions/{id}/review-comments` (Phase 6)
- `PATCH /api/review-comments/{id}` (Phase 6)
- `DELETE /api/review-comments/{id}` (Phase 6)
- `GET /api/sessions/{id}/search` (Phase 3 — command palette search)
- `GET /api/sessions/{id}/plugins` (Phase 9)
- `POST /api/sessions/{id}/plugins/install` (Phase 9)
- `POST /api/sessions/{id}/plugins/uninstall` (Phase 9)
- `POST /api/sessions/{id}/mcp/refresh` (Phase 9)
- Worktree endpoints (Phase 5 — already in `rest/worktrees.js`)

## Design System

The web frontend already has the Cosmic Harbor token system in `tokens.css`. All new components should use existing CSS custom properties — no raw colors, spacing, or font sizes.
