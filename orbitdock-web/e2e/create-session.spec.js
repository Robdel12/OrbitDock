import { expect } from '@playwright/test'
import { test } from './fixtures.js'

test.describe('Create Session Dialog', () => {
  test('opens dialog from sidebar button', async ({ authenticatedPage }) => {
    let { page, mockApi, goto } = authenticatedPage
    mockApi.setSessions([])

    await goto('/')

    await page.getByTitle('New Session').click()

    await expect(page.getByRole('heading', { name: 'New Session' })).toBeVisible()
    await expect(page.getByText('Working Directory')).toBeVisible()
    await expect(page.getByPlaceholder('/path/to/project')).toBeVisible()
  })

  test('has provider toggle between Claude and Codex', async ({ authenticatedPage }) => {
    let { page, mockApi, goto } = authenticatedPage
    mockApi.setSessions([])

    await goto('/')
    await page.getByTitle('New Session').click()

    await expect(page.getByRole('heading', { name: 'New Session' })).toBeVisible()
    await expect(page.getByRole('button', { name: 'Claude' })).toBeVisible()
    await expect(page.getByRole('button', { name: 'Codex' })).toBeVisible()
  })

  test('Create button is disabled without working directory', async ({ authenticatedPage }) => {
    let { page, mockApi, goto } = authenticatedPage
    mockApi.setSessions([])

    await goto('/')
    await page.getByTitle('New Session').click()
    await expect(page.getByRole('heading', { name: 'New Session' })).toBeVisible()

    let createBtn = page.getByRole('button', { name: 'Create' })
    await expect(createBtn).toBeDisabled()

    // Fill in a path — button should become enabled
    await page.getByPlaceholder('/path/to/project').fill('/Users/test/my-project')
    await expect(createBtn).toBeEnabled()
  })

  test('Cancel closes the dialog', async ({ authenticatedPage }) => {
    let { page, mockApi, goto } = authenticatedPage
    mockApi.setSessions([])

    await goto('/')
    await page.getByTitle('New Session').click()
    await expect(page.getByRole('heading', { name: 'New Session' })).toBeVisible()

    await page.getByRole('button', { name: 'Cancel' }).click()

    await expect(page.getByRole('heading', { name: 'New Session' })).not.toBeVisible()
  })

  test('submitting the form sends a POST to create session', async ({ authenticatedPage }) => {
    let { page, mockApi, goto } = authenticatedPage
    mockApi.setSessions([])

    await goto('/')
    await page.getByTitle('New Session').click()
    await expect(page.getByRole('heading', { name: 'New Session' })).toBeVisible()

    await page.getByPlaceholder('/path/to/project').fill('/Users/test/new-project')

    let [createRequest] = await Promise.all([
      page.waitForRequest((req) =>
        req.url().includes('/api/sessions') && req.method() === 'POST',
      ),
      page.getByRole('button', { name: 'Create' }).click(),
    ])

    let body = createRequest.postDataJSON()
    expect(body.provider).toBe('claude')
    expect(body.cwd).toBe('/Users/test/new-project')
  })
})
