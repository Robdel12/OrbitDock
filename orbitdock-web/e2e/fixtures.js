import { test as base, expect } from '@playwright/test'

// ── Mock data factories ─────────────────────────────────────────────────────

let idCounter = 0
let seqCounter = 0

const makeSession = (overrides = {}) => ({
  id: overrides.id || `sess-${++idCounter}`,
  status: 'active',
  work_status: 'reply',
  custom_name: null,
  display_title: overrides.display_title || `Test Session ${idCounter}`,
  summary: null,
  first_prompt: overrides.first_prompt || 'Hello, world',
  git_branch: overrides.git_branch || 'main',
  repository_root: overrides.repository_root || '/Users/test/project',
  project_path: overrides.project_path || '/Users/test/project',
  last_activity_at: overrides.last_activity_at || new Date().toISOString(),
  last_message: overrides.last_message || null,
  approval_policy: overrides.approval_policy || 'ask',
  model: overrides.model || 'claude-sonnet-4-20250514',
  provider: overrides.provider || 'claude',
  pending_approval: overrides.pending_approval || null,
  approval_version: overrides.approval_version || 0,
  ...overrides,
})

const makeConversationRow = (type, content, overrides = {}) => ({
  row_id: overrides.row_id || `row-${++idCounter}`,
  sequence: overrides.sequence ?? ++seqCounter,
  row_type: type,
  row: {
    row_type: type,
    content: content,
    ...overrides.row,
  },
})

const makeUserRow = (content, overrides = {}) =>
  makeConversationRow('user', content, overrides)

const makeAssistantRow = (content, overrides = {}) =>
  makeConversationRow('assistant', content, overrides)

// ── WebSocket mock script (injected via addInitScript) ──────────────────────

const WS_MOCK_SCRIPT = `
  window.__wsSent = [];
  window.__mockWsInstances = [];
  window.__wsReady = false;

  class MockWebSocket {
    static CONNECTING = 0;
    static OPEN = 1;
    static CLOSING = 2;
    static CLOSED = 3;

    constructor(url, protocols) {
      this.url = url;
      this.readyState = MockWebSocket.CONNECTING;
      this.onopen = null;
      this.onclose = null;
      this.onmessage = null;
      this.onerror = null;
      this.bufferedAmount = 0;
      this.extensions = '';
      this.protocol = '';
      this.binaryType = 'blob';

      window.__mockWsInstances.push(this);

      // Auto-open on next microtask
      Promise.resolve().then(() => {
        this.readyState = MockWebSocket.OPEN;
        window.__wsReady = true;
        if (this.onopen) this.onopen(new Event('open'));
      });
    }

    send(data) {
      if (this.readyState !== MockWebSocket.OPEN) return;
      window.__wsSent.push(JSON.parse(data));
    }

    close(code, reason) {
      this.readyState = MockWebSocket.CLOSED;
      if (this.onclose) {
        this.onclose(new CloseEvent('close', { code: code || 1000, reason: reason || '' }));
      }
    }

    addEventListener(type, listener) {
      this['on' + type] = listener;
    }

    removeEventListener() {}
    dispatchEvent() { return true; }
  }

  window.WebSocket = MockWebSocket;
`

// ── Fixtures ────────────────────────────────────────────────────────────────

let test = base.extend({
  mockApi: async ({ page }, use) => {
    // Install WebSocket mock before any page script runs
    await page.addInitScript(WS_MOCK_SCRIPT)

    let sessions = []
    let conversationData = {}
    let healthOk = true
    let authRequired = false



    let api = {
      setSessions(list) {
        sessions = list
      },

      setConversation(sessionId, data) {
        conversationData[sessionId] = data
      },

      setHealthOk(ok) {
        healthOk = ok
      },

      setAuthRequired(required) {
        authRequired = required
      },

      /** Send a WS message — waits for the mock WS to be ready first */
      async wsSend(message) {
        await page.waitForFunction(() => window.__wsReady === true, null, { timeout: 5000 })
        await page.evaluate((msg) => {
          let ws = window.__mockWsInstances[window.__mockWsInstances.length - 1]
          if (ws && ws.onmessage) {
            ws.onmessage(new MessageEvent('message', { data: JSON.stringify(msg) }))
          }
        }, message)
      },

      async getWsSent() {
        return page.evaluate(() => window.__wsSent || [])
      },
    }

    // ── Route handlers ──────────────────────────────────────────────────

    await page.route('**/health', (route) => {
      if (healthOk) {
        route.fulfill({ status: 200, contentType: 'application/json', body: '{"status":"ok"}' })
      } else {
        route.abort('connectionrefused')
      }
    })

    await page.route('**/api/sessions', (route) => {
      let request = route.request()
      let authHeader = request.headers()['authorization'] || ''

      if (authRequired && !authHeader.includes('odtk_')) {
        route.fulfill({ status: 401, contentType: 'application/json', body: '{"error":"unauthorized"}' })
        return
      }
      route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ sessions }),
      })
    })

    await page.route('**/api/sessions/*/conversation', (route) => {
      let url = route.request().url()
      let match = url.match(/\/api\/sessions\/([^/]+)\/conversation/)
      let sessionId = match?.[1]
      let data = conversationData[sessionId] || {
        session: { rows: [], total_row_count: 0, has_more_before: false },
      }
      route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify(data),
      })
    })

    await page.route('**/api/sessions/*/messages', (route) => {
      if (route.request().method() === 'POST') {
        route.fulfill({ status: 200, contentType: 'application/json', body: '{"ok":true}' })
      } else {
        route.continue()
      }
    })

    await page.route('**/api/sessions/*/approve', (route) => {
      route.fulfill({ status: 200, contentType: 'application/json', body: '{"ok":true}' })
    })

    await page.route('**/api/models/*', (route) => {
      route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ models: [] }),
      })
    })

    await page.route('**/api/missions', (route) => {
      route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ missions: [] }),
      })
    })

    await page.route('**/api/worktrees', (route) => {
      route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ worktrees: [] }),
      })
    })

    await page.route('**/api/sessions/*/config', (route) => {
      route.fulfill({ status: 200, contentType: 'application/json', body: '{"ok":true}' })
    })

    await page.route('**/api/sessions/*/name', (route) => {
      route.fulfill({ status: 200, contentType: 'application/json', body: '{"ok":true}' })
    })

    // Individual session endpoint (syncPendingApproval, etc.)
    await page.route(/\/api\/sessions\/[^/]+$/, (route) => {
      let url = route.request().url()
      if (url.endsWith('/sessions') || url.endsWith('/sessions/')) {
        route.fallback()
        return
      }
      let match = url.match(/\/api\/sessions\/([^/]+)$/)
      let sessionId = match?.[1]
      let session = sessions.find((s) => s.id === sessionId) || makeSession({ id: sessionId })
      route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ session }),
      })
    })

    // Skills / plugins (capabilities panel)
    await page.route('**/api/sessions/*/skills', (route) => {
      route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ skills: [] }),
      })
    })

    await page.route('**/api/sessions/*/plugins**', (route) => {
      route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ plugins: [] }),
      })
    })

    // Usage endpoints (dashboard usage-summary component)
    await page.route('**/api/usage/**', (route) => {
      route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ usage: [] }),
      })
    })

    // Filesystem browsing (mention completions)
    await page.route('**/api/fs/**', (route) => {
      route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ entries: [] }),
      })
    })

    // POST to create session (must be registered last so fallback works)
    await page.route('**/api/sessions', (route) => {
      if (route.request().method() === 'POST') {
        let newSession = makeSession({ display_title: 'New Session' })
        route.fulfill({
          status: 201,
          contentType: 'application/json',
          body: JSON.stringify({ session: newSession }),
        })
      } else {
        route.fallback()
      }
    })

    await use(api)
  },

  /**
   * Pre-authenticated page. Seeds localStorage with a token, navigates to
   * the given URL, and waits for the WS mock to connect + sessions to load.
   *
   * Use `goto(url)` instead of `page.goto()` to benefit from auto-waiting.
   */
  authenticatedPage: async ({ page, mockApi }, use) => {
    await page.addInitScript(() => {
      localStorage.setItem('orbitdock_auth_token', 'odtk_test_token_12345')
    })

    let goto = async (url = '/') => {
      await page.goto(url)
      // Wait for the sidebar "Connected" text — auth passed, WS connected.
      await expect(page.getByText('Connected')).toBeVisible({ timeout: 10000 })
    }

    await use({ page, mockApi, goto })
  },
})

export { test, makeSession, makeConversationRow, makeUserRow, makeAssistantRow }
