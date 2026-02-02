#!/usr/bin/env node

/**
 * Codex notify hook - called on agent-turn-complete
 *
 * Input (stdin JSON):
 * {
 *   "session_id": "abc-123", // or conversation_id / thread_id / session.id
 *   ...
 * }
 */

import { readFileSync } from 'node:fs'
import { execSync } from 'node:child_process'
import { getDb, updateSession } from '../lib/db.js'
import { createLogger } from '../lib/logger.js'

let log = createLogger('codex-notify')

let notifyApp = () => {
  try {
    execSync('notifyutil -p com.orbitdock.session.updated', { stdio: 'ignore' })
  } catch {}
}

let resolveSessionId = (input) => {
  if (!input || typeof input !== 'object') return null
  return (
    input.session_id ||
    input['session-id'] ||
    input.conversation_id ||
    input['conversation-id'] ||
    input.thread_id ||
    input['thread-id'] ||
    input.session?.id ||
    input.conversation?.id ||
    null
  )
}

let main = async () => {
  let input
  let db

  log.info('Codex notify hook triggered')

  try {
    let rawInput = process.argv[2] || readFileSync(0, 'utf-8')
    if (!rawInput.trim()) {
      log.debug('No input received, exiting')
      process.exit(0)
    }

    try {
      input = JSON.parse(rawInput)
    } catch (parseErr) {
      log.error('Failed to parse input JSON', { error: parseErr.message })
      process.exit(0)
    }

    log.info('Notify payload keys', { keys: Object.keys(input || {}) })

    let sessionId = resolveSessionId(input)
    if (!sessionId) {
      log.warn('Missing session id in notify payload')
      process.exit(0)
    }

    db = getDb()

    // Capture terminal info - this hook runs inside the terminal process
    let terminalSessionId = process.env.ITERM_SESSION_ID || null
    let terminalApp = process.env.TERM_PROGRAM || null

    updateSession(db, sessionId, {
      workStatus: 'waiting',
      attentionReason: 'awaitingReply',
      pendingToolName: null,
      pendingToolInput: null,
      pendingQuestion: null,
      terminalSessionId,
      terminalApp,
    })

    notifyApp()
    log.info('Marked session waiting from Codex notify', { sessionId })
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
