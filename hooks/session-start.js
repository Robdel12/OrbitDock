#!/usr/bin/env node

/**
 * Session start hook - called when Claude Code starts a new session
 *
 * Input (stdin JSON):
 * {
 *   "session_id": "abc-123",
 *   "cwd": "/path/to/project",
 *   "model": "claude-opus-4-5-20251101"
 * }
 */

import { readFileSync } from 'node:fs'
import { execSync } from 'node:child_process'
import { ensureSchema, getDb } from '../lib/db.js'
import { handleSessionStart } from '../lib/workstream.js'
import { createLogger } from '../lib/logger.js'

let log = createLogger('session-start')

let notifyApp = () => {
  try {
    execSync('notifyutil -p com.orbitdock.session.updated', { stdio: 'ignore' })
  } catch {}
}

let main = async () => {
  let input
  let db

  log.info('SessionStart hook triggered')

  try {
    let rawInput = readFileSync(0, 'utf-8')
    if (!rawInput.trim()) {
      log.debug('No input received, exiting')
      process.exit(0)
    }

    try {
      input = JSON.parse(rawInput)
    } catch (parseErr) {
      log.error('Failed to parse input JSON', { error: parseErr.message })
      process.exit(1)
    }

    // source: startup, resume, clear, compact
    log.info('Session start received', {
      sessionId: input.session_id,
      cwd: input.cwd,
      model: input.model,
      source: input.source
    })

    if (!input.session_id) {
      log.warn('Missing session_id in input')
      process.exit(1)
    }

    if (!input.cwd) {
      log.warn('Missing cwd in input')
      process.exit(1)
    }

    db = getDb()
    ensureSchema(db)

    let terminalSessionId = process.env.ITERM_SESSION_ID || null
    let terminalApp = process.env.TERM_PROGRAM || null

    let result = handleSessionStart(db, {
      sessionId: input.session_id,
      projectPath: input.cwd,
      model: input.model,
      contextLabel: input.context_label,
      transcriptPath: input.transcript_path,
      terminalSessionId,
      terminalApp,
    })

    notifyApp()

    if (result.workstream) {
      log.info('Session linked to workstream', { sessionId: input.session_id, workstream: result.workstream.name || result.workstream.branch })
    } else {
      log.info('Session started (no workstream)', { sessionId: input.session_id })
    }
  } catch (err) {
    log.error('Hook error', { error: err.message, stack: err.stack })
  } finally {
    if (db) {
      try {
        db.close()
      } catch {}
    }
  }
}

main()
