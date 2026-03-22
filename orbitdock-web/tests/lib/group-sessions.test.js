import assert from 'node:assert/strict'
import { describe, it } from 'node:test'
import { extractRepoName, groupByRepo } from '../../src/lib/group-sessions.js'

const makeSession = (id, repoRoot, status = 'active', lastActivity = '2026-01-01T00:00:00Z') => ({
  id,
  repository_root: repoRoot,
  status,
  last_activity_at: lastActivity,
})

describe('extractRepoName', () => {
  it('extracts the last path segment', () => {
    assert.strictEqual(extractRepoName('/Users/rob/Developer/OrbitDock'), 'OrbitDock')
  })

  it('strips trailing slashes', () => {
    assert.strictEqual(extractRepoName('/Users/rob/Developer/OrbitDock/'), 'OrbitDock')
  })

  it('returns Unknown for null or empty', () => {
    assert.strictEqual(extractRepoName(null), 'Unknown')
    assert.strictEqual(extractRepoName(''), 'Unknown')
  })
})

describe('groupByRepo', () => {
  it('groups sessions by repository_root', () => {
    const sessions = [makeSession('s1', '/repo/a'), makeSession('s2', '/repo/b'), makeSession('s3', '/repo/a')]
    const groups = groupByRepo(sessions)
    assert.strictEqual(groups.length, 2)

    const groupA = groups.find((g) => g.path === '/repo/a')
    assert.strictEqual(groupA.sessions.length, 2)

    const groupB = groups.find((g) => g.path === '/repo/b')
    assert.strictEqual(groupB.sessions.length, 1)
  })

  it('sorts groups by most recent activity', () => {
    const sessions = [
      makeSession('s1', '/repo/old', 'active', '2026-01-01T00:00:00Z'),
      makeSession('s2', '/repo/new', 'active', '2026-03-01T00:00:00Z'),
    ]
    const groups = groupByRepo(sessions)
    assert.strictEqual(groups[0].path, '/repo/new')
    assert.strictEqual(groups[1].path, '/repo/old')
  })

  it('sorts sessions within a group: active before ended, then by recency', () => {
    const sessions = [
      makeSession('s1', '/repo/a', 'ended', '2026-03-01T00:00:00Z'),
      makeSession('s2', '/repo/a', 'active', '2026-01-01T00:00:00Z'),
      makeSession('s3', '/repo/a', 'active', '2026-02-01T00:00:00Z'),
    ]
    const groups = groupByRepo(sessions)
    const ids = groups[0].sessions.map((s) => s.id)
    // Active sessions first (s3 more recent than s2), then ended (s1)
    assert.deepStrictEqual(ids, ['s3', 's2', 's1'])
  })

  it('falls back to project_path when repository_root is missing', () => {
    const sessions = [{ id: 's1', project_path: '/fallback/path', status: 'active', last_activity_at: null }]
    const groups = groupByRepo(sessions)
    assert.strictEqual(groups[0].path, '/fallback/path')
  })

  it('uses Unknown when both paths are missing', () => {
    const sessions = [{ id: 's1', status: 'active', last_activity_at: null }]
    const groups = groupByRepo(sessions)
    assert.strictEqual(groups[0].path, 'Unknown')
    assert.strictEqual(groups[0].name, 'Unknown')
  })

  it('returns empty for empty input', () => {
    assert.deepStrictEqual(groupByRepo([]), [])
  })
})
