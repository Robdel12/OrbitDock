import assert from 'node:assert'
import { describe, it } from 'node:test'
import Database from 'better-sqlite3'

import {
  addNote,
  addTicket,
  cleanupStaleSessions,
  createWorkstream,
  ensureSchema,
  findOrCreateRepo,
  getNotes,
  getTickets,
  getUnresolvedBlockers,
  upsertSession,
} from './db.js'

import { detectBranchCreation, detectWorktreePath, parseLinearIssueFromBranch } from './git.js'

// ============================================================================
// Pure function tests - no I/O, no mocking
// ============================================================================

describe('detectBranchCreation', () => {
  let bash = (cmd) => detectBranchCreation('Bash', { command: cmd })

  it('detects git checkout -b', () => {
    assert.strictEqual(bash('git checkout -b feature/new-thing'), 'feature/new-thing')
  })

  it('detects git switch -c', () => {
    assert.strictEqual(bash('git switch -c fix/bug-123'), 'fix/bug-123')
  })

  it('detects git branch', () => {
    assert.strictEqual(bash('git branch my-branch'), 'my-branch')
  })

  it('returns null for non-Bash tools', () => {
    assert.strictEqual(detectBranchCreation('Read', { file: 'foo.js' }), null)
    assert.strictEqual(detectBranchCreation('Write', { content: 'x' }), null)
  })

  it('returns null for non-branch commands', () => {
    assert.strictEqual(bash('npm install'), null)
    assert.strictEqual(bash('git status'), null)
    assert.strictEqual(bash('git checkout main'), null)
    assert.strictEqual(bash('git push'), null)
  })

  it('handles complex branch names', () => {
    assert.strictEqual(
      bash('git checkout -b feat/VIZ-123-add-dark-mode'),
      'feat/VIZ-123-add-dark-mode',
    )
    assert.strictEqual(bash('git switch -c user/rob/experiment'), 'user/rob/experiment')
  })

  it('ignores branch delete commands', () => {
    assert.strictEqual(bash('git branch -d old-branch'), null)
    assert.strictEqual(bash('git branch -D old-branch'), null)
  })
})

describe('parseLinearIssueFromBranch', () => {
  it('extracts Linear issue from branch name', () => {
    assert.strictEqual(parseLinearIssueFromBranch('viz-42-add-dark-mode'), 'VIZ-42')
    assert.strictEqual(parseLinearIssueFromBranch('feature/VIZ-123-thing'), 'VIZ-123')
    assert.strictEqual(parseLinearIssueFromBranch('fix/abc-999'), 'ABC-999')
  })

  it('returns null for branches without issue ID', () => {
    assert.strictEqual(parseLinearIssueFromBranch('feature/add-auth'), null)
    assert.strictEqual(parseLinearIssueFromBranch('main'), null)
    assert.strictEqual(parseLinearIssueFromBranch('fix-typo'), null)
  })

  it('handles null/undefined', () => {
    assert.strictEqual(parseLinearIssueFromBranch(null), null)
    assert.strictEqual(parseLinearIssueFromBranch(undefined), null)
  })
})

describe('detectWorktreePath', () => {
  it('extracts path from git worktree add', () => {
    assert.strictEqual(
      detectWorktreePath({ command: 'git worktree add ../my-worktree feature/thing' }),
      '../my-worktree',
    )
    assert.strictEqual(
      detectWorktreePath({ command: 'git worktree add -b new-branch /tmp/worktree' }),
      '/tmp/worktree',
    )
  })

  it('returns null for non-worktree commands', () => {
    assert.strictEqual(detectWorktreePath({ command: 'git checkout -b foo' }), null)
    assert.strictEqual(detectWorktreePath({ command: 'npm install' }), null)
  })
})

// ============================================================================
// Database integration tests - real SQLite, no mocking
// ============================================================================

describe('database operations', () => {
  let db

  function freshDb() {
    db = new Database(':memory:')
    db.pragma('journal_mode = WAL')
    ensureSchema(db)
    return db
  }

  it('creates repo and workstream', () => {
    freshDb()

    let repo = findOrCreateRepo(db, { path: '/test/repo', name: 'test-repo' })
    assert.ok(repo.id)
    assert.strictEqual(repo.path, '/test/repo')

    let ws = createWorkstream(db, { repoId: repo.id, branch: 'feature/test' })
    assert.ok(ws.id)
    assert.strictEqual(ws.branch, 'feature/test')
    assert.strictEqual(ws.stage, 'working')
  })

  it('adds and retrieves notes', () => {
    freshDb()
    let repo = findOrCreateRepo(db, { path: '/test/repo', name: 'test-repo' })
    let ws = createWorkstream(db, { repoId: repo.id, branch: 'feature/notes' })

    let note = addNote(db, {
      workstreamId: ws.id,
      type: 'decision',
      content: 'Using SQLite for simplicity',
    })

    assert.ok(note.id)
    assert.strictEqual(note.type, 'decision')
    assert.strictEqual(note.content, 'Using SQLite for simplicity')

    let notes = getNotes(db, ws.id)
    assert.strictEqual(notes.length, 1)
    assert.strictEqual(notes[0].content, 'Using SQLite for simplicity')
  })

  it('tracks unresolved blockers', () => {
    freshDb()
    let repo = findOrCreateRepo(db, { path: '/test/repo', name: 'test-repo' })
    let ws = createWorkstream(db, { repoId: repo.id, branch: 'feature/blockers' })

    addNote(db, { workstreamId: ws.id, type: 'blocker', content: 'Waiting on API access' })
    addNote(db, { workstreamId: ws.id, type: 'note', content: 'Regular note' })
    addNote(db, { workstreamId: ws.id, type: 'blocker', content: 'Need design review' })

    let blockers = getUnresolvedBlockers(db, ws.id)
    assert.strictEqual(blockers.length, 2)

    let notes = getNotes(db, ws.id)
    assert.strictEqual(notes.length, 3)
  })

  it('adds and updates tickets', () => {
    freshDb()
    let repo = findOrCreateRepo(db, { path: '/test/repo', name: 'test-repo' })
    let ws = createWorkstream(db, { repoId: repo.id, branch: 'feature/tickets' })

    let ticket = addTicket(db, {
      workstreamId: ws.id,
      source: 'linear',
      externalId: 'VIZ-123',
      title: 'Add dark mode',
      state: 'Todo',
      isPrimary: true,
    })

    assert.strictEqual(ticket.external_id, 'VIZ-123')
    assert.strictEqual(ticket.is_primary, 1)

    // Update via upsert
    let updated = addTicket(db, {
      workstreamId: ws.id,
      source: 'linear',
      externalId: 'VIZ-123',
      title: 'Add dark mode',
      state: 'In Progress',
      isPrimary: true,
    })

    assert.strictEqual(updated.state, 'In Progress')

    let tickets = getTickets(db, ws.id)
    assert.strictEqual(tickets.length, 1)
  })

  it('finds existing repo by path', () => {
    freshDb()

    let repo1 = findOrCreateRepo(db, { path: '/test/repo', name: 'test-repo' })
    let repo2 = findOrCreateRepo(db, { path: '/test/repo', name: 'different-name' })

    assert.strictEqual(repo1.id, repo2.id)
  })

  it('cleans up stale sessions in same terminal', () => {
    freshDb()

    // Create two sessions in same terminal
    upsertSession(db, {
      id: 'session-old',
      projectPath: '/test',
      status: 'active',
      terminalSessionId: 'term-123',
    })
    upsertSession(db, {
      id: 'session-new',
      projectPath: '/test',
      status: 'active',
      terminalSessionId: 'term-123',
    })

    // Both should be active initially
    let oldSession = db.prepare('SELECT status FROM sessions WHERE id = ?').get('session-old')
    assert.strictEqual(oldSession.status, 'active')

    // Cleanup should mark old session as stale
    let cleaned = cleanupStaleSessions(db, 'term-123', 'session-new')
    assert.strictEqual(cleaned, 1)

    // Old session should now be ended
    oldSession = db
      .prepare('SELECT status, end_reason FROM sessions WHERE id = ?')
      .get('session-old')
    assert.strictEqual(oldSession.status, 'ended')
    assert.strictEqual(oldSession.end_reason, 'stale')

    // New session should still be active
    let newSession = db.prepare('SELECT status FROM sessions WHERE id = ?').get('session-new')
    assert.strictEqual(newSession.status, 'active')
  })
})
