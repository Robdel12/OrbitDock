#!/usr/bin/env node

/**
 * Session end hook - called when Claude Code session ends
 *
 * Input (stdin JSON):
 * {
 *   "session_id": "abc-123",
 *   "cwd": "/path/to/project",
 *   "reason": "clear" | "logout" | "prompt_input_exit" | "bypass_permissions_disabled" | "other"
 * }
 */

import { readFileSync } from 'node:fs'
import { execSync } from 'node:child_process'
import { getDb } from '../lib/db.js'
import { handleSessionEnd } from '../lib/workstream.js'
import { createLogger } from '../lib/logger.js'

let log = createLogger('session-end')

let notifyApp = () => {
  try {
    execSync('notifyutil -p com.orbitdock.session.updated', { stdio: 'ignore' })
  } catch {}
}

let main = async () => {
  let input
  let db

  log.info('SessionEnd hook triggered')

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

    // reason: clear, logout, prompt_input_exit, bypass_permissions_disabled, other
    log.info('Session end received', { sessionId: input.session_id, reason: input.reason })

    if (!input.session_id) {
      log.warn('Missing session_id')
      process.exit(1)
    }

    db = getDb()

    handleSessionEnd(db, {
      sessionId: input.session_id,
      reason: input.reason,
    })

    notifyApp()

    log.info('Session ended', { sessionId: input.session_id, reason: input.reason || 'unknown' })
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
