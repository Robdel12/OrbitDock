#!/usr/bin/env node

/**
 * Tool tracker hook - called for each tool use
 * Detects branch creation and updates session status
 *
 * Input (stdin JSON):
 * {
 *   "session_id": "abc-123",
 *   "cwd": "/path/to/project",
 *   "tool_name": "Bash",
 *   "tool_input": { "command": "git checkout -b feat/new-feature" }
 * }
 */

import { readFileSync } from 'node:fs'
import { getDb } from '../lib/db.js'
import { handleToolUse } from '../lib/workstream.js'

const LOG_PREFIX = '[OrbitDock:tool-tracker]'

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
      // Silently ignore parse errors for tool tracker
      process.exit(0)
    }

    if (!input.session_id || !input.cwd) {
      process.exit(0)
    }

    db = getDb()

    const result = handleToolUse(db, {
      sessionId: input.session_id,
      toolName: input.tool_name,
      toolInput: input.tool_input,
      projectPath: input.cwd,
    })

    if (result.branchCreated) {
      console.error(
        `${LOG_PREFIX} New workstream created: ${result.workstream.name || result.workstream.branch}`,
      )
    }
  } catch (err) {
    // Silently fail - tool tracking shouldn't block Claude
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
