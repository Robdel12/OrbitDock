/**
 * Database module - shared SQLite access for hooks and MCP server
 *
 * Pure functions for database operations. All functions take a db connection
 * as the first parameter for testability.
 */

import { homedir } from 'node:os'
import { join } from 'node:path'
import Database from 'better-sqlite3'
import { migrate, getCurrentVersion } from './migrate.js'

// Database path - separate from Claude to survive reinstalls
// Can be overridden via ORBITDOCK_DB_PATH env var for testing
const DB_PATH = process.env.ORBITDOCK_DB_PATH || join(homedir(), '.orbitdock', 'orbitdock.db')

/**
 * Get a database connection with WAL mode enabled
 */
export const getDb = (path = DB_PATH) => {
  const db = new Database(path)
  db.pragma('journal_mode = WAL')
  db.pragma('busy_timeout = 5000')
  return db
}

/**
 * Ensure schema is up to date by running pending migrations
 */
export const ensureSchema = (db) => {
  let applied = migrate(db)
  // Only log if not in test mode and migrations were applied
  if (applied.length > 0 && !process.env.NODE_TEST_CONTEXT) {
    console.log(`Applied ${applied.length} migration(s): ${applied.map((m) => m.name).join(', ')}`)
  }
}

/**
 * Get current schema version
 */
export const getSchemaVersion = (db) => {
  return getCurrentVersion(db)
}

// ============================================================================
// Repo Operations
// ============================================================================

export const findOrCreateRepo = (db, { path, name, githubOwner, githubName }) => {
  const id = Buffer.from(path).toString('base64url')

  const existing = db.prepare('SELECT * FROM repos WHERE path = ?').get(path)
  if (existing) return existing

  const now = new Date().toISOString()
  db.prepare(`
    INSERT INTO repos (id, name, path, github_owner, github_name, created_at)
    VALUES (?, ?, ?, ?, ?, ?)
  `).run(id, name, path, githubOwner || null, githubName || null, now)

  return db.prepare('SELECT * FROM repos WHERE id = ?').get(id)
}

export const getRepoByPath = (db, path) => {
  return db.prepare('SELECT * FROM repos WHERE path = ?').get(path)
}

// ============================================================================
// Workstream Operations
// ============================================================================

export const findWorkstreamByBranch = (db, repoId, branch) => {
  return db
    .prepare(`
    SELECT * FROM workstreams
    WHERE repo_id = ? AND branch = ?
  `)
    .get(repoId, branch)
}

export const createWorkstream = (db, { repoId, branch, directory, name }) => {
  const id = `ws-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`
  const now = new Date().toISOString()

  db.prepare(`
    INSERT INTO workstreams (id, repo_id, branch, directory, name, stage, review_approvals, review_comments, session_count, total_session_seconds, commit_count, created_at, updated_at)
    VALUES (?, ?, ?, ?, ?, 'working', 0, 0, 0, 0, 0, ?, ?)
  `).run(id, repoId, branch, directory || null, name || null, now, now)

  return db.prepare('SELECT * FROM workstreams WHERE id = ?').get(id)
}

export const getWorkstream = (db, id) => {
  return db.prepare('SELECT * FROM workstreams WHERE id = ?').get(id)
}

export const updateWorkstream = (db, id, updates) => {
  const fields = Object.keys(updates)
    .map((k) => `${toSnakeCase(k)} = ?`)
    .join(', ')
  const values = Object.values(updates)

  db.prepare(`
    UPDATE workstreams
    SET ${fields}, updated_at = datetime('now')
    WHERE id = ?
  `).run(...values, id)

  return db.prepare('SELECT * FROM workstreams WHERE id = ?').get(id)
}

export const getWorkstreamWithRelations = (db, id) => {
  const workstream = getWorkstream(db, id)
  if (!workstream) return null

  const tickets = db
    .prepare(`
    SELECT * FROM workstream_tickets WHERE workstream_id = ?
  `)
    .all(id)

  const notes = db
    .prepare(`
    SELECT * FROM workstream_notes WHERE workstream_id = ? ORDER BY created_at DESC
  `)
    .all(id)

  const sessions = db
    .prepare(`
    SELECT * FROM sessions WHERE workstream_id = ? ORDER BY started_at DESC
  `)
    .all(id)

  return { ...workstream, tickets, notes, sessions }
}

// ============================================================================
// Ticket Operations
// ============================================================================

export const addTicket = (
  db,
  { workstreamId, source, externalId, title, state, url, isPrimary },
) => {
  const id = `ticket-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`
  const now = new Date().toISOString()

  db.prepare(`
    INSERT INTO workstream_tickets (id, workstream_id, source, external_id, title, state, url, is_primary, created_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(workstream_id, source, external_id) DO UPDATE SET
      title = excluded.title,
      state = excluded.state,
      url = excluded.url,
      is_primary = excluded.is_primary
  `).run(
    id,
    workstreamId,
    source,
    externalId,
    title || null,
    state || null,
    url || null,
    isPrimary ? 1 : 0,
    now,
  )

  return db
    .prepare(`
    SELECT * FROM workstream_tickets
    WHERE workstream_id = ? AND source = ? AND external_id = ?
  `)
    .get(workstreamId, source, externalId)
}

export const getTickets = (db, workstreamId) => {
  return db
    .prepare(`
    SELECT * FROM workstream_tickets WHERE workstream_id = ?
  `)
    .all(workstreamId)
}

// ============================================================================
// Note Operations
// ============================================================================

export const addNote = (db, { workstreamId, type, content, sessionId }) => {
  const id = `note-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`
  const now = new Date().toISOString()

  db.prepare(`
    INSERT INTO workstream_notes (id, workstream_id, type, content, session_id, created_at)
    VALUES (?, ?, ?, ?, ?, ?)
  `).run(id, workstreamId, type || 'note', content, sessionId || null, now)

  return db.prepare('SELECT * FROM workstream_notes WHERE id = ?').get(id)
}

export const resolveNote = (db, noteId) => {
  const now = new Date().toISOString()
  db.prepare(`
    UPDATE workstream_notes SET resolved_at = ? WHERE id = ?
  `).run(now, noteId)
}

export const getNotes = (db, workstreamId) => {
  return db
    .prepare(`
    SELECT * FROM workstream_notes
    WHERE workstream_id = ?
    ORDER BY created_at DESC
  `)
    .all(workstreamId)
}

export const getUnresolvedBlockers = (db, workstreamId) => {
  return db
    .prepare(`
    SELECT * FROM workstream_notes
    WHERE workstream_id = ? AND type = 'blocker' AND resolved_at IS NULL
    ORDER BY created_at DESC
  `)
    .all(workstreamId)
}

// ============================================================================
// Session Operations
// ============================================================================

export const upsertSession = (db, session) => {
  const {
    id,
    projectPath,
    projectName,
    branch,
    model,
    contextLabel,
    transcriptPath,
    status,
    workStatus,
    startedAt,
    workstreamId,
    terminalSessionId,
    terminalApp,
  } = session

  db.prepare(`
    INSERT INTO sessions (
      id, project_path, project_name, branch, model, context_label,
      transcript_path, status, work_status, started_at, last_activity_at,
      workstream_id, terminal_session_id, terminal_app
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now'), ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET
      project_path = excluded.project_path,
      project_name = excluded.project_name,
      branch = excluded.branch,
      model = excluded.model,
      context_label = excluded.context_label,
      transcript_path = excluded.transcript_path,
      status = excluded.status,
      work_status = excluded.work_status,
      last_activity_at = datetime('now'),
      workstream_id = COALESCE(excluded.workstream_id, workstream_id),
      terminal_session_id = COALESCE(excluded.terminal_session_id, terminal_session_id),
      terminal_app = COALESCE(excluded.terminal_app, terminal_app)
  `).run(
    id,
    projectPath,
    projectName || null,
    branch || null,
    model || null,
    contextLabel || null,
    transcriptPath || null,
    status || 'active',
    workStatus || 'unknown',
    startedAt || new Date().toISOString(),
    workstreamId || null,
    terminalSessionId || null,
    terminalApp || null,
  )

  return db.prepare('SELECT * FROM sessions WHERE id = ?').get(id)
}

export const getSession = (db, id) => {
  return db.prepare('SELECT * FROM sessions WHERE id = ?').get(id)
}

export const updateSession = (db, id, updates) => {
  const fields = Object.keys(updates)
    .map((k) => `${toSnakeCase(k)} = ?`)
    .join(', ')
  const values = Object.values(updates)

  db.prepare(`
    UPDATE sessions
    SET ${fields}, last_activity_at = datetime('now')
    WHERE id = ?
  `).run(...values, id)

  return db.prepare('SELECT * FROM sessions WHERE id = ?').get(id)
}

export const endSession = (db, id, reason) => {
  db.prepare(`
    UPDATE sessions
    SET status = 'ended', ended_at = datetime('now'), end_reason = ?
    WHERE id = ?
  `).run(reason || null, id)
}

export const incrementPromptCount = (db, id) => {
  db.prepare(`
    UPDATE sessions
    SET prompt_count = prompt_count + 1, last_activity_at = datetime('now')
    WHERE id = ?
  `).run(id)
}

export const incrementToolCount = (db, id) => {
  db.prepare(`
    UPDATE sessions
    SET tool_count = tool_count + 1, last_activity_at = datetime('now')
    WHERE id = ?
  `).run(id)
}

/**
 * Mark stale sessions as ended
 * A terminal can only run one Claude session at a time, so if we're starting
 * a new session in this terminal, any old active sessions must have ended without cleanup
 */
export const cleanupStaleSessions = (db, terminalSessionId, currentSessionId) => {
  if (!terminalSessionId) return 0

  const result = db
    .prepare(`
    UPDATE sessions
    SET status = 'ended', ended_at = datetime('now'), end_reason = 'stale'
    WHERE terminal_session_id = ?
      AND status = 'active'
      AND id != ?
  `)
    .run(terminalSessionId, currentSessionId)

  return result.changes
}

// ============================================================================
// Helpers
// ============================================================================

const toSnakeCase = (str) => str.replace(/[A-Z]/g, (letter) => `_${letter.toLowerCase()}`)
