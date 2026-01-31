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
import { ensureSchema, getDb } from './lib/db.js'
import { handleSessionStart } from './lib/workstream.js'

const LOG_PREFIX = '[OrbitDock:session-start]'

const main = async () => {
  let input
  let db

  try {
    // Read and parse input
    const rawInput = readFileSync(0, 'utf-8')
    if (!rawInput.trim()) {
      console.error(`${LOG_PREFIX} No input received`)
      process.exit(0) // Not an error, just no input
    }

    try {
      input = JSON.parse(rawInput)
    } catch (parseErr) {
      console.error(`${LOG_PREFIX} Failed to parse input JSON:`, parseErr.message)
      process.exit(1)
    }

    // Validate required fields
    if (!input.session_id) {
      console.error(`${LOG_PREFIX} Missing session_id in input`)
      process.exit(1)
    }

    if (!input.cwd) {
      console.error(`${LOG_PREFIX} Missing cwd in input`)
      process.exit(1)
    }

    // Initialize database
    db = getDb()
    ensureSchema(db)

    // Capture terminal info from environment
    const terminalSessionId = process.env.ITERM_SESSION_ID || null
    const terminalApp = process.env.TERM_PROGRAM || null

    // Handle session start
    const result = handleSessionStart(db, {
      sessionId: input.session_id,
      projectPath: input.cwd,
      model: input.model,
      contextLabel: input.context_label,
      transcriptPath: input.transcript_path,
      terminalSessionId,
      terminalApp,
    })

    // Log result (goes to stderr, not visible to user)
    if (result.workstream) {
      console.error(
        `${LOG_PREFIX} Session ${input.session_id} linked to workstream: ${result.workstream.name || result.workstream.branch}`,
      )
    } else {
      console.error(
        `${LOG_PREFIX} Session ${input.session_id} started (no workstream - on main branch)`,
      )
    }
  } catch (err) {
    console.error(`${LOG_PREFIX} Error:`, err.message)
    // Don't exit with error code - hook failures shouldn't block Claude
  } finally {
    if (db) {
      try {
        db.close()
      } catch (closeErr) {
        console.error(`${LOG_PREFIX} Failed to close database:`, closeErr.message)
      }
    }
  }
}

main()
