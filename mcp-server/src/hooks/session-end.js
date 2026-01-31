#!/usr/bin/env node

/**
 * Session end hook - called when Claude Code session ends
 *
 * Input (stdin JSON):
 * {
 *   "session_id": "abc-123",
 *   "cwd": "/path/to/project",
 *   "end_reason": "user_exit" | "error" | etc
 * }
 */

import { readFileSync } from 'node:fs'
import { getDb } from '../db.js'
import { handleSessionEnd } from '../workstream.js'

const LOG_PREFIX = '[OrbitDock:session-end]'

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
    } catch (parseErr) {
      console.error(`${LOG_PREFIX} Failed to parse input JSON:`, parseErr.message)
      process.exit(1)
    }

    if (!input.session_id) {
      console.error(`${LOG_PREFIX} Missing session_id`)
      process.exit(1)
    }

    db = getDb()

    handleSessionEnd(db, {
      sessionId: input.session_id,
      reason: input.end_reason,
    })

    console.error(
      `${LOG_PREFIX} Session ${input.session_id} ended (${input.end_reason || 'unknown'})`,
    )
  } catch (err) {
    console.error(`${LOG_PREFIX} Error:`, err.message)
  } finally {
    if (db) {
      try {
        db.close()
      } catch {}
    }
  }
}

main()
