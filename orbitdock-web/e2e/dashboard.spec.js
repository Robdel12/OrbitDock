import { expect } from '@playwright/test'
import { makeSession, test } from './fixtures.js'

test.describe('Dashboard', () => {
  test('renders session cards from server data', async ({ authenticatedPage }) => {
    let { page, mockApi, goto } = authenticatedPage
    let sessions = [
      makeSession({ id: 's-1', display_title: 'Fix auth bug', work_status: 'reply', repository_root: '/Users/test/project-a' }),
      makeSession({ id: 's-2', display_title: 'Add dark mode', work_status: 'working', repository_root: '/Users/test/project-b' }),
    ]
    mockApi.setSessions(sessions)

    await goto('/')

    // Session cards are buttons in the main content area
    await expect(page.getByRole('button', { name: /Fix auth bug/ })).toBeVisible()
    await expect(page.getByRole('button', { name: /Add dark mode/ })).toBeVisible()
  })

  test('shows greeting text', async ({ authenticatedPage }) => {
    let { page, mockApi, goto } = authenticatedPage
    mockApi.setSessions([makeSession({ id: 's-1', display_title: 'My Session' })])

    await goto('/')

    await expect(page.getByText(/Good (morning|afternoon|evening)/)).toBeVisible()
  })

  test('shows session count summary', async ({ authenticatedPage }) => {
    let { page, mockApi, goto } = authenticatedPage
    let sessions = [
      makeSession({ id: 's-1', work_status: 'working' }),
      makeSession({ id: 's-2', work_status: 'reply' }),
      makeSession({ id: 's-3', work_status: 'permission' }),
    ]
    mockApi.setSessions(sessions)

    await goto('/')

    await expect(page.getByText(/3.*session/)).toBeVisible()
  })

  test('filters sessions by zone', async ({ authenticatedPage }) => {
    let { page, mockApi, goto } = authenticatedPage
    let sessions = [
      makeSession({ id: 's-1', display_title: 'Needs Approval', work_status: 'permission' }),
      makeSession({ id: 's-2', display_title: 'Currently Working', work_status: 'working' }),
      makeSession({ id: 's-3', display_title: 'Ready To Go', work_status: 'reply' }),
    ]
    mockApi.setSessions(sessions)

    await goto('/')

    // All session cards (buttons) visible
    await expect(page.getByRole('button', { name: /Needs Approval/ })).toBeVisible()
    await expect(page.getByRole('button', { name: /Currently Working/ })).toBeVisible()
    await expect(page.getByRole('button', { name: /Ready To Go/ })).toBeVisible()

    // Click attention filter — chip label is "Attn"
    await page.getByText('Attn').click()

    // Only attention session card should be visible
    await expect(page.getByRole('button', { name: /Needs Approval/ })).toBeVisible()
    await expect(page.getByRole('button', { name: /Currently Working/ })).not.toBeVisible()
    await expect(page.getByRole('button', { name: /Ready To Go/ })).not.toBeVisible()
  })

  test('navigates to session on click', async ({ authenticatedPage }) => {
    let { page, mockApi, goto } = authenticatedPage
    let sessions = [
      makeSession({ id: 'sess-click-1', display_title: 'Clickable Session' }),
    ]
    mockApi.setSessions(sessions)

    await goto('/')

    await page.getByRole('button', { name: /Clickable Session/ }).click()

    await expect(page).toHaveURL(/\/session\/sess-click-1/)
  })

  test('keyboard navigation works (j/k to move, Enter to open)', async ({ authenticatedPage }) => {
    let { page, mockApi, goto } = authenticatedPage
    // Explicit timestamps so sort order (newest first) is deterministic
    let sessions = [
      makeSession({ id: 'sess-kb-1', display_title: 'First Session', repository_root: '/test/repo', last_activity_at: '2026-01-01T00:00:02Z' }),
      makeSession({ id: 'sess-kb-2', display_title: 'Second Session', repository_root: '/test/repo', last_activity_at: '2026-01-01T00:00:01Z' }),
    ]
    mockApi.setSessions(sessions)

    await goto('/')

    await expect(page.getByRole('button', { name: /First Session/ })).toBeVisible()

    // Sorted newest-first: sess-kb-1 (index 0), sess-kb-2 (index 1)
    // j moves from -1 → 0, j again moves to 1, Enter opens sess-kb-2
    await page.keyboard.press('j')
    await page.keyboard.press('j')
    await page.keyboard.press('Enter')

    await expect(page).toHaveURL(/\/session\/sess-kb-2/)
  })
})
