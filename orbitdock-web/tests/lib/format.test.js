import assert from 'node:assert/strict'
import { describe, it } from 'node:test'
import { formatDuration, formatRelativeTime, formatTokenCount } from '../../src/lib/format.js'

describe('formatDuration', () => {
  it('formats milliseconds', () => {
    assert.strictEqual(formatDuration(500), '500ms')
  })

  it('formats seconds with one decimal', () => {
    assert.strictEqual(formatDuration(1500), '1.5s')
    assert.strictEqual(formatDuration(45000), '45.0s')
  })

  it('formats minutes and seconds', () => {
    assert.strictEqual(formatDuration(90000), '1m 30s')
    assert.strictEqual(formatDuration(3600000), '60m 0s')
  })

  it('returns null for null or undefined', () => {
    assert.strictEqual(formatDuration(null), null)
    assert.strictEqual(formatDuration(undefined), null)
  })
})

describe('formatTokenCount', () => {
  it('formats small counts as-is', () => {
    assert.strictEqual(formatTokenCount(42), '42')
    assert.strictEqual(formatTokenCount(999), '999')
  })

  it('formats thousands with k suffix', () => {
    assert.strictEqual(formatTokenCount(1500), '1.5k')
    assert.strictEqual(formatTokenCount(10000), '10.0k')
  })

  it('formats millions with M suffix', () => {
    assert.strictEqual(formatTokenCount(1500000), '1.5M')
  })

  it('returns empty string for null or undefined', () => {
    assert.strictEqual(formatTokenCount(null), '')
    assert.strictEqual(formatTokenCount(undefined), '')
  })
})

describe('formatRelativeTime', () => {
  it('returns empty string for falsy input', () => {
    assert.strictEqual(formatRelativeTime(null), '')
    assert.strictEqual(formatRelativeTime(''), '')
  })

  it('returns empty string for invalid dates', () => {
    assert.strictEqual(formatRelativeTime('not-a-date'), '')
  })

  it('returns "just now" for future timestamps', () => {
    const future = new Date(Date.now() + 60000).toISOString()
    assert.strictEqual(formatRelativeTime(future), 'just now')
  })

  it('returns "now" for timestamps less than 60 seconds ago', () => {
    const recent = new Date(Date.now() - 10000).toISOString()
    assert.strictEqual(formatRelativeTime(recent), 'now')
  })

  it('returns minutes for 1-59 minute old timestamps', () => {
    const fiveMinAgo = new Date(Date.now() - 5 * 60 * 1000).toISOString()
    assert.strictEqual(formatRelativeTime(fiveMinAgo), '5m')
  })

  it('returns hours for 1-23 hour old timestamps', () => {
    const twoHoursAgo = new Date(Date.now() - 2 * 60 * 60 * 1000).toISOString()
    assert.strictEqual(formatRelativeTime(twoHoursAgo), '2h')
  })

  it('returns days for 1-6 day old timestamps', () => {
    const threeDaysAgo = new Date(Date.now() - 3 * 24 * 60 * 60 * 1000).toISOString()
    assert.strictEqual(formatRelativeTime(threeDaysAgo), '3d')
  })

  it('returns weeks for 7+ day old timestamps', () => {
    const twoWeeksAgo = new Date(Date.now() - 14 * 24 * 60 * 60 * 1000).toISOString()
    assert.strictEqual(formatRelativeTime(twoWeeksAgo), '2w')
  })

  it('accepts unix epoch seconds as a number', () => {
    const fiveMinAgo = (Date.now() - 5 * 60 * 1000) / 1000
    assert.strictEqual(formatRelativeTime(fiveMinAgo), '5m')
  })
})
