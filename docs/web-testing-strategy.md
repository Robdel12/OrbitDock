# Web Testing Strategy

Testing guidance for `orbitdock-web`. Covers where each kind of test belongs, what we avoid, and how to decide the right level for new tests.

---

## Test Pyramid

Two layers, no middle ground:

| Layer | Tool | What it covers |
|-------|------|----------------|
| **E2E / UI workflow** | Playwright | Multi-step user flows through a real browser |
| **Logic unit** | `node:test` + `node:assert/strict` | Pure functions, state machines, stores, codecs |

There is no broad component-harness layer in between. We do not use happy-dom tests as the primary way to verify that features work. The few component tests that exist verify rendering contracts (does the component render the right data given specific props?) — they are not workflow tests.

---

## What Belongs Where

### Playwright (UI workflows)

Use Playwright when the thing you're testing is **a user workflow that crosses multiple components and relies on real browser behavior**.

Good candidates:

- Opening a session, sending a message, and seeing the response appear
- Approving a tool request from the approval banner
- Navigating between dashboard and session detail
- Keyboard shortcuts (j/k navigation, Escape to go back)
- Composer interactions (Enter to send, Shift+Enter for newline, slash command dispatch)
- Scroll-to-bottom / infinite scroll pagination

### Node-native unit tests (pure logic)

Use `node:test` when the thing you're testing is **deterministic logic with no DOM dependency**, or a **small rendering contract**.

Good candidates:

- **State machines** — XState actors that model connection lifecycle, approval flow, etc. Feed events, assert state. No DOM needed.
- **Stores** — Signal-based stores that reconcile REST + WebSocket data. Call methods, assert signal values.
- **Codecs** — Message encoding/decoding, row type classification, unknown-variant resilience.
- **Pure functions** — Sorting, filtering, formatting, data transformation helpers.
- **Rendering contracts** — A component renders the right text/structure given specific props. Use `@testing-library/preact` + `happy-dom`, keep it small.

---

## What We Don't Want

### Broad component integration tests in happy-dom

Don't test multi-step user workflows by wiring up a component tree in happy-dom and simulating clicks through it. That's Playwright's job. Happy-dom is a DOM shim, not a browser — it misses layout, scroll behavior, focus management, real CSS, and network timing.

**Bad:** A test that renders the full `SessionView`, mocks the WebSocket, sends fake messages, and asserts that the conversation updates and the approval banner appears.

**Good:** A Playwright test that does the same thing in a real browser against a running server.

### Tests that duplicate what the server already guarantees

The server owns state. Don't write client tests that re-verify server business logic (approval version ordering, session state transitions, message sequencing). Test that the client *reacts correctly* to server data — not that the server data is correct.

### Snapshot tests

Don't use snapshot testing for component output. Snapshots break on every cosmetic change and teach you nothing when they fail.

---

## Mocking Rules

Mock at **true external boundaries only**:

| OK to mock | Not OK to mock |
|------------|----------------|
| Network requests (`fetch`, WebSocket messages) | Internal stores or signals |
| Browser APIs not available in Node (e.g., `IntersectionObserver`) | Other components in the same app |
| Time (`mock.timers`) when testing debounce/retry logic | XState actors (test the real machine) |

If you find yourself mocking three things to test one thing, the test is probably at the wrong level. Either push it up to Playwright or pull the logic out into a pure function.

---

## Waiting and Synchronization

- **No `setTimeout`.** Not in tests, not in production code. There is almost never a use case for it.
- **No arbitrary delays or sleep loops.** If a test needs to wait for something, wait for the actual condition (a DOM change, a signal update, an actor state transition).
- **Playwright has built-in waiting.** Use locator assertions (`expect(locator).toBeVisible()`) which auto-retry. Don't add manual waits.
- **Unit tests are synchronous by default.** State machine and store tests should be fully deterministic — send an event, assert the result immediately.

---

## Decision Guide

When you're about to write a test, ask:

1. **Is this a user-visible workflow?** → Playwright
2. **Is this pure logic I can test with plain data in / data out?** → `node:test`
3. **Is this a rendering contract (component shows X given Y props)?** → `node:test` + `@testing-library/preact`, keep it small
4. **Am I about to mock more than one internal module?** → Wrong level. Reconsider.
5. **Am I about to simulate a multi-step flow in happy-dom?** → Wrong level. Use Playwright.

---

## Examples From This Codebase

### Good: State machine unit test

```js
// tests/machines/approval.machine.test.js
it('stale requests do not override the current approval', () => {
  const actor = startActor()
  actor.send({ type: 'APPROVAL_REQUESTED', request: { id: 'req-1', type: 'exec' }, approval_version: 5 })
  actor.send({ type: 'APPROVAL_REQUESTED', request: { id: 'req-2', type: 'exec' }, approval_version: 3 })
  assert.strictEqual(snap(actor).context.request.id, 'req-1')
  actor.stop()
})
```

Pure state transitions. No DOM, no mocks, no waits. Tests a real business rule (version gating) that would be error-prone to verify any other way.

### Good: Rendering contract test

```js
// tests/components/tool-row.test.jsx
it('displays the command, location, timing, and output preview', () => {
  const { getByText } = render(<ToolRow entry={makeToolEntry()} />)
  assert.ok(getByText('ls -la'))
  assert.ok(getByText('/Users/rob/project'))
  assert.ok(getByText('0.5s'))
})
```

Verifies that `ToolRow` renders the right data from `tool_display`. Small, focused, no workflow simulation.

### Good: Store reconciliation test

```js
// tests/stores/conversation.test.js
it('updates an existing message when content changes', () => {
  const store = createConversationStore()
  store.applyBootstrap({ rows: [makeEntry('r-1', 1, 'assistant', 'hello')], total_row_count: 1 })
  store.applyRowsChanged({
    upserted: [makeEntry('r-1', 1, 'assistant', 'hello world')],
    removed_row_ids: [],
    total_row_count: 1,
  })
  assert.strictEqual(store.rows.value[0].row.content, 'hello world')
})
```

Tests the dedup/upsert logic that reconciles REST and WebSocket data. Pure signals, no DOM.

### Bad: Full workflow in happy-dom

```js
// ❌ Don't do this
it('sends a message and shows the response', () => {
  const fakeWs = new FakeWebSocket()
  const { getByRole, getByText } = render(<App websocket={fakeWs} />)
  fireEvent.change(getByRole('textbox'), { target: { value: 'Hello' } })
  fireEvent.click(getByRole('button', { name: 'Send' }))
  fakeWs.simulateMessage({ type: 'conversation_rows_changed', upserted: [{ ... }] })
  assert.ok(getByText('Assistant response'))
})
```

This is a user workflow test pretending to be a unit test. It needs a fake WebSocket, a fake DOM, and component wiring — and it still misses real scroll behavior, focus, and layout. Put this in Playwright.

---

## Running Tests

```bash
# Unit tests
cd orbitdock-web
npm test                    # run once
npm run test:watch          # watch mode

# Lint + format
npm run lint
npm run format:check
```

Playwright setup is tracked separately. When added, it will run against a real `orbitdock` server instance.
