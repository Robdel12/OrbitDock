import { expect } from '@playwright/test'
import { test } from './fixtures.js'

test.describe('Navigation', () => {
  test('sidebar links navigate between pages', async ({ authenticatedPage }) => {
    let { page, mockApi, goto } = authenticatedPage
    mockApi.setSessions([])

    await goto('/')

    // Navigate to Missions via sidebar
    await page.getByRole('link', { name: 'Missions' }).click()
    await expect(page).toHaveURL('/missions')

    // Navigate to Worktrees
    await page.getByRole('link', { name: 'Worktrees' }).click()
    await expect(page).toHaveURL('/worktrees')

    // Navigate to Settings
    await page.getByRole('link', { name: 'Settings' }).click()
    await expect(page).toHaveURL('/settings')

    // Navigate back to Sessions (dashboard)
    await page.getByRole('link', { name: 'Sessions' }).click()
    await expect(page).toHaveURL('/')
  })

  test('sidebar shows session list grouped by repo', async ({ authenticatedPage }) => {
    let { page, mockApi, goto } = authenticatedPage
    let sessions = [
      {
        id: 'nav-s-1',
        status: 'active',
        work_status: 'reply',
        display_title: 'Fix bug',
        repository_root: '/Users/test/project-alpha',
        project_path: '/Users/test/project-alpha',
        provider: 'claude',
        model: 'claude-sonnet-4-20250514',
        last_activity_at: new Date().toISOString(),
        approval_policy: 'ask',
        approval_version: 0,
        pending_approval: null,
      },
      {
        id: 'nav-s-2',
        status: 'active',
        work_status: 'working',
        display_title: 'Add feature',
        repository_root: '/Users/test/project-beta',
        project_path: '/Users/test/project-beta',
        provider: 'claude',
        model: 'claude-sonnet-4-20250514',
        last_activity_at: new Date().toISOString(),
        approval_policy: 'ask',
        approval_version: 0,
        pending_approval: null,
      },
    ]
    mockApi.setSessions(sessions)

    await goto('/')

    let sidebar = page.locator('aside')

    // Sidebar should show repo group labels
    await expect(sidebar.getByText('project-alpha')).toBeVisible()
    await expect(sidebar.getByText('project-beta')).toBeVisible()

    // Session names should appear in sidebar
    await expect(sidebar.getByText('Fix bug')).toBeVisible()
    await expect(sidebar.getByText('Add feature')).toBeVisible()
  })

  test('clicking a session in sidebar navigates to it', async ({ authenticatedPage }) => {
    let { page, mockApi, goto } = authenticatedPage
    let sessions = [
      {
        id: 'nav-click-1',
        status: 'active',
        work_status: 'reply',
        display_title: 'Sidebar Session',
        repository_root: '/Users/test/repo',
        project_path: '/Users/test/repo',
        provider: 'claude',
        model: 'claude-sonnet-4-20250514',
        last_activity_at: new Date().toISOString(),
        approval_policy: 'ask',
        approval_version: 0,
        pending_approval: null,
      },
    ]
    mockApi.setSessions(sessions)
    mockApi.setConversation('nav-click-1', {
      session: { rows: [], total_row_count: 0, has_more_before: false },
    })

    await goto('/')

    let sidebar = page.locator('aside')
    await sidebar.getByText('Sidebar Session').click()

    await expect(page).toHaveURL(/\/session\/nav-click-1/)
  })

  test('shows connection status in sidebar footer', async ({ authenticatedPage }) => {
    let { page, mockApi, goto } = authenticatedPage
    mockApi.setSessions([])

    await goto('/')

    await expect(page.getByText('Connected')).toBeVisible()
  })

  test('shows 404 page for unknown routes', async ({ authenticatedPage }) => {
    let { page, mockApi, goto } = authenticatedPage
    mockApi.setSessions([])

    await goto('/nonexistent')

    await expect(page.getByRole('heading', { name: '404' })).toBeVisible()
    await expect(page.getByText('Page not found')).toBeVisible()
  })
})
