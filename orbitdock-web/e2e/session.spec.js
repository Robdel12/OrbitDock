import { expect } from '@playwright/test'
import { makeAssistantRow, makeSession, makeUserRow, test } from './fixtures.js'

test.describe('Session Detail', () => {
  let sessionId = 'sess-detail-1'
  let session = makeSession({
    id: sessionId,
    display_title: 'Test Conversation',
    work_status: 'reply',
  })

  test('renders conversation rows', async ({ authenticatedPage }) => {
    let { page, mockApi, goto } = authenticatedPage
    mockApi.setSessions([session])
    mockApi.setConversation(sessionId, {
      session: {
        rows: [
          makeUserRow('Hello, can you help me?', { row_id: 'r-1', sequence: 1 }),
          makeAssistantRow('Of course! What do you need help with?', { row_id: 'r-2', sequence: 2 }),
        ],
        total_row_count: 2,
        has_more_before: false,
      },
    })

    await goto(`/session/${sessionId}`)

    await expect(page.getByText('Hello, can you help me?')).toBeVisible()
    await expect(page.getByText('Of course! What do you need help with?')).toBeVisible()
  })

  test('sends a message via the composer', async ({ authenticatedPage }) => {
    let { page, mockApi, goto } = authenticatedPage
    mockApi.setSessions([session])
    mockApi.setConversation(sessionId, {
      session: { rows: [], total_row_count: 0, has_more_before: false },
    })

    await goto(`/session/${sessionId}`)

    let composer = page.locator('[contenteditable="true"]')
    await expect(composer).toBeVisible()
    await composer.click()
    await composer.pressSequentially('Build me a spaceship')

    let [sendRequest] = await Promise.all([
      page.waitForRequest((req) =>
        req.url().includes(`/api/sessions/${sessionId}/messages`) && req.method() === 'POST',
      ),
      page.keyboard.press('Enter'),
    ])

    let body = sendRequest.postDataJSON()
    expect(body.content).toBe('Build me a spaceship')
  })

  test('shows approval banner for exec requests', async ({ authenticatedPage }) => {
    let { page, mockApi, goto } = authenticatedPage
    mockApi.setSessions([session])
    mockApi.setConversation(sessionId, {
      session: {
        rows: [makeUserRow('Run the tests', { row_id: 'r-1', sequence: 1 })],
        total_row_count: 1,
        has_more_before: false,
        pending_approval: {
          id: 'approval-1',
          type: 'exec',
          tool_name: 'Bash',
          command: 'npm test',
          cwd: '/Users/test/project',
        },
        approval_version: 1,
      },
    })

    await goto(`/session/${sessionId}`)

    await expect(page.getByText('npm test')).toBeVisible()
    await expect(page.getByText('APPROVAL')).toBeVisible()
    await expect(page.getByRole('button', { name: 'Allow' })).toBeVisible()
    await expect(page.getByRole('button', { name: 'Deny' })).toBeVisible()
  })

  test('approving sends the decision to the server', async ({ authenticatedPage }) => {
    let { page, mockApi, goto } = authenticatedPage
    mockApi.setSessions([session])
    mockApi.setConversation(sessionId, {
      session: {
        rows: [],
        total_row_count: 0,
        has_more_before: false,
        pending_approval: {
          id: 'approval-2',
          type: 'exec',
          tool_name: 'Bash',
          command: 'cargo build',
          cwd: '/project',
        },
        approval_version: 1,
      },
    })

    await goto(`/session/${sessionId}`)

    await expect(page.getByRole('button', { name: 'Allow' })).toBeVisible()

    let [approveRequest] = await Promise.all([
      page.waitForRequest((req) =>
        req.url().includes(`/api/sessions/${sessionId}/approve`) && req.method() === 'POST',
      ),
      page.getByRole('button', { name: 'Allow' }).click(),
    ])

    let body = approveRequest.postDataJSON()
    expect(body.request_id).toBe('approval-2')
    expect(body.decision).toBe('approved')
  })

  test('shows status indicator based on work_status', async ({ authenticatedPage }) => {
    let { page, mockApi, goto } = authenticatedPage
    let workingSession = makeSession({
      id: 'sess-working',
      display_title: 'Working Session',
      work_status: 'working',
    })
    mockApi.setSessions([workingSession])
    mockApi.setConversation('sess-working', {
      session: { rows: [], total_row_count: 0, has_more_before: false },
    })

    await goto('/session/sess-working')

    // The conversation status indicator has a specific class — use exact text + role
    let statusIndicator = page.getByText('Working', { exact: true })
    await expect(statusIndicator.first()).toBeVisible()
  })

  test('Escape navigates back to dashboard from session', async ({ authenticatedPage }) => {
    let { page, mockApi, goto } = authenticatedPage
    mockApi.setSessions([session])
    mockApi.setConversation(sessionId, {
      session: { rows: [], total_row_count: 0, has_more_before: false },
    })

    await goto(`/session/${sessionId}`)

    // Wait for session to load, then blur the composer
    let composer = page.locator('[contenteditable="true"]')
    await expect(composer).toBeVisible()
    await composer.blur()

    await page.keyboard.press('Escape')

    await expect(page).toHaveURL('/')
  })
})
