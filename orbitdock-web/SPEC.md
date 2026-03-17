# OrbitDock Web Frontend — Living Spec

Single source of truth for `orbitdock-web`. Updated as implementation evolves.

---

## 1. Overview

Lightweight Preact web client for OrbitDock, an alternative to the native SwiftUI macOS app. The server owns all state — this client is a thin reactive view over REST + WebSocket.

| Concern | Choice |
|---------|--------|
| UI framework | Preact 10 + `@preact/signals` 2 |
| Build | Vite 8 + `@preact/preset-vite` 2.10 |
| State machines | XState 5 |
| Routing | wouter-preact 3 |
| Markdown | marked 15 |
| Icons | lucide-preact |
| Styling | CSS Modules + CSS custom properties |
| Testing | Vitest 3 + `@testing-library/preact` + happy-dom |
| Language | Plain JavaScript (no TypeScript) |

---

## 2. Architecture

### 2.1 Project Structure

```
src/
  api/
    codec.js              Message encode/decode, known type registries
    http.js               HTTP client factory with error handling
    ws.js                 WebSocket client (signals-based)
    rest/
      index.js            Barrel — 8 API modules
      sessions.js         Session CRUD, messages, approvals
      approvals.js        Approval endpoints
      server.js           Health, models, keys, usage
      worktrees.js        Worktree management
      missions.js         Mission Control endpoints
      filesystem.js       File/directory reads
      reviews.js          Review comments
      codex.js            Codex auth + models
  components/
    approval/             ApprovalBanner
    conversation/         12 row types, row dispatcher, conversation view,
                          diff view, tool expanded detail
    input/                MessageComposer
    layout/               AppShell, Header, Sidebar
    session/              SessionCard, SessionList, SessionHeader,
                          CreateSessionDialog, StatusIndicator
    ui/                   Button, Badge, Card, EdgeBar, Spinner,
                          StatusDot, IconButton, Skeleton, ErrorBoundary
  hooks/
    use-keyboard.js       Global keyboard shortcuts
    use-machine.js        XState actor → Preact hook bridge
    use-scroll-anchor.js  Pin-to-bottom with IntersectionObserver
    use-session.js        Subscribe/unsubscribe session lifecycle
  lib/
    format.js             Date/time/size formatting
    group-sessions.js     Group sessions by repo for dashboard
    icons.js              Icon resolution helpers
    markdown.js           Markdown → HTML rendering
  machines/
    connection.machine.js XState: disconnected → connecting → connected → reconnecting → failed
    approval.machine.js   XState: idle → pending → submitting (version-gated)
  pages/
    dashboard.jsx         Grouped session list with keyboard nav
    session.jsx           Conversation + composer + approval + header
    settings.jsx          Models, API keys, usage, connection
    missions.jsx          Mission list
    mission-detail.jsx    Mission detail with issues
    not-found.jsx         404
  stores/
    connection.js         WS ↔ signals bridge, message routing
    conversation.js       Row upsert/remove/sort, pagination
    sessions.js           Signal Map + computed grouped view
  styles/
    global.css            Global styles
    reset.css             CSS reset
    tokens.css            Design tokens (Cosmic Harbor theme)
  routes.js               Data-driven route table
  app.jsx                 Root component with router
  main.jsx                Entry point
```

### 2.2 State Management

- **Signals** for simple reactive state (session list, conversation rows, connection status). Shared across components via module-level singletons.
- **XState 5** for complex lifecycles with multiple states and guards:
  - Connection machine: manages WS connect/reconnect/fail with exponential backoff (max 10 attempts, up to 30s delay).
  - Approval machine: version-gated state transitions to prevent stale/duplicate approval banners.
- **No global state library.** Stores are plain modules exporting signals and mutation functions.

### 2.3 API Layer

- **REST** for all reads and mutations (`/api/*`). HTTP client factory in `api/http.js` with JSON handling and error normalization.
- **WebSocket** for subscriptions and real-time session interaction (`/ws`). Signal-based client in `api/ws.js` with codec decoding.
- **Connection bridge** in `stores/connection.js` routes incoming WS messages to the appropriate store handlers via a flat switch on `msg.type`.

### 2.4 Component System

- Base UI primitives in `components/ui/` with a `variant` + `size` API (e.g., `<Button variant="primary" size="sm">`).
- CSS Modules for component-scoped styles. CSS custom properties defined in `tokens.css` for theming.
- EdgeBar pattern: colored left border on cards indicating status/type.
- Conversation rows: each row type has its own component + CSS module. Row dispatcher maps `row.type` to component with unknown-type resilience.

---

## 3. Key Decisions & Lessons Learned

Things discovered during implementation that were not obvious from the original plan.

### WS does NOT deliver initial payloads

`subscribe_list` and `subscribe_session` only register for incremental broadcasts. Initial data must always come from REST. This was the biggest gap in the original plan — the connection bridge fires `GET /api/sessions` immediately after subscribing.

### `subscribe_session` with `include_snapshot: true` returns `http_only_endpoint` error

Always use `include_snapshot: false`. Initial conversation data comes from `GET /api/sessions/{id}/conversation`.

### REST responses are envelope-wrapped

`{ sessions: [...] }` not bare arrays. `{ session: {...} }` not bare objects. The stores must unwrap these.

### Pagination uses `/messages` not `/conversation`

`/conversation` is the initial bootstrap (rows + metadata). `/messages?before_sequence=X` is for infinite-scroll pagination of older rows.

### Rename endpoint is `PATCH /sessions/{id}/name`

Not `PATCH /sessions/{id}`. The body is `{ name }`.

### Send message path is `/messages` (plural)

Not `/message` (singular). `POST /api/sessions/{id}/messages`.

### XState 5 `machine.getInitialSnapshot()` requires actor scope

Cannot get a snapshot from the machine definition alone. Must create an actor first, then read `actor.getSnapshot()`.

### Preact signals: `signal()` inside component body creates new signal every render

Use `useState` or `useRef` for component-local state. Use module-level `signal()` for shared stores. Never call `signal()` in a render function.

### Vite 8 works with `@preact/preset-vite@2.10.x`

Earlier Vite 6 had a compatibility issue with the preset. Pin to 2.10.x for Vite 8 support.

### Codec uses a known-type whitelist

Unknown WS message types are logged and dropped (returns `null`). Unknown conversation row types render a generic fallback in the row dispatcher. Both registries (`KNOWN_SERVER_TYPES`, `KNOWN_ROW_TYPES`) live in `api/codec.js`.

---

## 4. Server Contract Reference

See [`plans/web-frontend-api-spec.md`](../plans/web-frontend-api-spec.md) for the full API integration reference. Key patterns:

### Connection Flow

1. Open WS to `/ws`
2. Receive `server_info` (immediate)
3. Send `{ type: "subscribe_list" }` (registers for incremental updates)
4. `GET /api/sessions` (fetches initial session list)
5. WS delivers `session_created` / `session_list_item_updated` / `session_ended` incrementally

### Session View Flow

1. Send `{ type: "subscribe_session", session_id, include_snapshot: false }`
2. `GET /api/sessions/{id}/conversation?limit=50` (initial rows)
3. WS delivers `conversation_rows_changed` incrementally
4. For older messages: `GET /api/sessions/{id}/messages?before_sequence=X`

### Approval Flow

1. WS receives `approval_requested` with `approval_version`
2. Only process if `approval_version > high_water_mark` (prevents stale replays)
3. User decides via REST (`POST /api/sessions/{id}/approve|answer|permissions/respond`)
4. WS receives `approval_decision_result` with new `approval_version`
5. Machine transitions: idle -> pending -> submitting -> idle

### Store Reconciliation

REST and WS operate in parallel. Stores handle race conditions:
- Session list: REST replaces all; WS upserts/removes incrementally
- Conversation: REST bootstraps; WS applies `upserted` by `row_id`, removes by `removed_row_ids`, sorts by sequence
- Approvals: version high water mark prevents stale/duplicate banners

---

## 5. What's Built (Phases 1-3)

### Foundation
- [x] Project scaffold (Vite 8, Preact, CSS Modules, plain JS)
- [x] CSS design tokens — Cosmic Harbor theme (80+ custom properties)
- [x] HTTP client factory with error handling
- [x] WebSocket client with Preact signals
- [x] Message codec with known-type whitelist and unknown variant resilience
- [x] 8 REST API modules (sessions, approvals, server, worktrees, missions, filesystem, reviews, codex)

### State Management
- [x] Connection state machine (XState 5: disconnected -> connecting -> connected -> reconnecting -> failed)
- [x] Approval state machine (XState 5: idle -> pending -> submitting, version-gated)
- [x] Session store (signal Map + computed grouped view)
- [x] Conversation store (upsert/remove/sort by sequence, pagination via `loadOlder`)
- [x] Connection bridge (WS <-> signals, message routing for 16+ message types)

### UI Primitives
- [x] Button (primary/secondary/ghost/danger, sm/md/lg)
- [x] Badge (status/tool/meta variants)
- [x] Card with optional EdgeBar
- [x] StatusDot with pulse animation
- [x] Spinner, IconButton, Skeleton/SkeletonRow/SkeletonCard, ErrorBoundary

### Pages & Navigation
- [x] Dashboard (grouped session list, keyboard nav with j/k/arrows/Enter)
- [x] Session detail (conversation + composer + approval banner + header actions)
- [x] Settings (models, API keys, usage, connection)
- [x] Mission Control (list + detail with issues)
- [x] 404 page
- [x] Data-driven routing via wouter-preact (6 routes)

### Conversation
- [x] 12 row type components (user, assistant, thinking, system, tool, activity_group, question, approval, worker, plan, hook, handoff)
- [x] Row dispatcher with unknown type fallback
- [x] Markdown rendering (marked) in user + assistant rows
- [x] Tool card click-to-expand with lazy REST content loading (`/rows/{row_id}/content`)
- [x] Diff view with line numbers and add/remove coloring
- [x] Thinking row collapsed preview
- [x] Pin-to-bottom scroll with IntersectionObserver
- [x] Pagination (load older via REST `/messages?before_sequence=X`)
- [x] Streaming cursor for `is_streaming` rows

### Session Management
- [x] Create session dialog (provider toggle, model picker, cwd input)
- [x] Session header with status and actions (interrupt/undo/compact/end)
- [x] Message composer with auto-resize and stop button
- [x] Approval banner (exec/patch/question/permissions types)

### Keyboard
- [x] j/k/arrows for session list navigation
- [x] Enter to open session
- [x] Escape to go back to dashboard

### Testing
- [x] 50 tests across 7 test files (all passing)
- [x] `codec.test.js` — 11 tests: encode/decode, known types, unknown resilience
- [x] `connection.machine.test.js` — 8 tests: state transitions, reconnect, retry limits
- [x] `approval.machine.test.js` — 8 tests: version gating, submit flow, error recovery
- [x] `conversation.test.js` — 6 tests: bootstrap, upsert, remove, sort, pagination
- [x] `row-dispatcher.test.jsx` — 5 tests: type mapping, unknown fallback
- [x] `tool-row.test.jsx` — 6 tests: render, expand, content loading
- [x] `session-card.test.jsx` — 6 tests: render, status display, click handling

---

## 6. What's Remaining (Phase 4+)

### Features
- [ ] Worktree management UI (list, create, delete — REST module exists, no pages)
- [ ] Session search UI (REST endpoint wired, no search input)
- [ ] Session fork/resume UI (endpoints wired, no UI triggers beyond header)
- [ ] Toast notifications for off-screen approvals
- [ ] Image attachment support in composer
- [ ] Model selector in composer
- [ ] Session config editing (approval policy, sandbox mode)
- [ ] Subagent conversation drill-down
- [ ] MCP tools/skills browser
- [ ] Codex auth flow UI
- [ ] Review comments UI
- [ ] Shell execution UI

### Polish
- [ ] Responsive sidebar (collapse on narrow viewports)
- [ ] Accessibility audit (aria labels, focus management, screen reader testing)
- [ ] Code splitting / lazy routes for larger pages
- [ ] Bundle optimization (tree-shake lucide, split marked)

---

## 7. Build & Test Commands

From `orbitdock-web/`:

```
npm install          # Install dependencies
npm run dev          # Dev server on :3000 (proxies to server on :4000)
npm run build        # Production build
npm test             # Run tests (vitest run)
npm run test:watch   # Watch mode (vitest)
```

From the repo root:

```
make web-install
make web-dev
make web-build
make web-test
```
