#!/usr/bin/env node

/**
 * Status tracker hook - tracks session work status
 * Called on status changes (working, waiting, permission needed)
 *
 * Input (stdin JSON):
 * {
 *   "session_id": "abc-123",
 *   "cwd": "/path/to/project",
 *   "status": "working" | "waiting" | "permission"
 * }
 */

import { readFileSync } from 'node:fs'
import { getDb } from '../lib/db.js'
import { handleStatusChange } from '../lib/workstream.js'

const LOG_PREFIX = '[OrbitDock:status-tracker]'

const main = async () => {
  let input
  let db

  try {
    // Read and parse input
    const rawInput = readFileSync(0, 'utf-8')
    if (!rawInput.trim()) {
      process.exit(0)
    }

    try {
      input = JSON.parse(rawInput)
    } catch (_parseErr) {
      // Silently ignore parse errors
      process.exit(0)
    }

    if (!input.session_id || !input.status) {
      process.exit(0)
    }

    db = getDb()

    handleStatusChange(db, {
      sessionId: input.session_id,
      status: input.status,
    })
  } catch (err) {
    // Silently fail - status tracking shouldn't block Claude
    if (process.env.ORBITDOCK_DEBUG) {
      console.error(`${LOG_PREFIX} Error:`, err.message)
    }
  } finally {
    if (db) {
      try {
        db.close()
      } catch {}
    }
  }
}

main()
