import { expect } from '@playwright/test'
import { test } from './fixtures.js'

test.describe('Authentication', () => {
  test('shows token input when auth is required', async ({ page, mockApi }) => {
    mockApi.setAuthRequired(true)

    await page.goto('/')

    await expect(page.getByRole('heading', { name: 'OrbitDock' })).toBeVisible()
    await expect(page.getByPlaceholder('odtk_...')).toBeVisible()
    await expect(page.getByRole('button', { name: 'Connect' })).toBeVisible()
  })

  test('shows error on invalid token', async ({ page, mockApi }) => {
    mockApi.setAuthRequired(true)

    await page.goto('/')
    await expect(page.getByPlaceholder('odtk_...')).toBeVisible()

    // Enter an invalid token (doesn't contain odtk_)
    await page.getByPlaceholder('odtk_...').fill('bad_token_value')
    await page.getByRole('button', { name: 'Connect' }).click()

    await expect(page.getByText('Invalid token')).toBeVisible()
  })

  test('proceeds to dashboard after valid token', async ({ page, mockApi }) => {
    mockApi.setAuthRequired(true)
    mockApi.setSessions([])

    await page.goto('/')
    await expect(page.getByPlaceholder('odtk_...')).toBeVisible()

    // Enter a valid token
    await page.getByPlaceholder('odtk_...').fill('odtk_valid_test_token')
    await page.getByRole('button', { name: 'Connect' }).click()

    // Should pass auth gate — check for sidebar logo
    await expect(page.getByText('OrbitDock').first()).toBeVisible()
  })

  test('shows server unreachable when health check fails', async ({ page, mockApi }) => {
    mockApi.setHealthOk(false)

    await page.goto('/')

    await expect(page.getByRole('heading', { name: 'Server Unreachable' })).toBeVisible()
    await expect(page.getByRole('button', { name: 'Retry' })).toBeVisible()
  })

  test('bypasses auth when no token is required', async ({ page, mockApi }) => {
    mockApi.setAuthRequired(false)
    mockApi.setSessions([])

    await page.goto('/')

    // Should go straight to dashboard (sidebar visible)
    await expect(page.getByText('OrbitDock').first()).toBeVisible()
  })
})
