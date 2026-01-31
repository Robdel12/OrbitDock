#!/usr/bin/env node

/**
 * Tool tracker hook - tracks tool usage
 * Handles: PreToolUse, PostToolUse, PostToolUseFailure
 *
 * Input (stdin JSON):
 * {
 *   "session_id": "abc-123",
 *   "cwd": "/path/to/project",
 *   "hook_event_name": "PreToolUse" | "PostToolUse" | "PostToolUseFailure",
 *   "tool_name": "Bash",
 *   "tool_input": { "command": "git checkout -b feat/new-feature" },
 *   "tool_use_id": "toolu_01ABC...",
 *   "error": "error message (PostToolUseFailure only)",
 *   "is_interrupt": false (PostToolUseFailure only)
 * }
 */

import { readFileSync } from 'node:fs'
import { execSync } from 'node:child_process'
import { getDb, updateSession, incrementToolCount } from '../lib/db.js'
import * as git from '../lib/git.js'
import * as db from '../lib/db.js'
import { createLogger } from '../lib/logger.js'

let log = createLogger('tool-tracker')

let notifyApp = () => {
  try {
    execSync('notifyutil -p com.orbitdock.session.updated', { stdio: 'ignore' })
  } catch {}
}

let main = () => {
  let input
  let database

  try {
    let rawInput = readFileSync(0, 'utf-8')
    if (!rawInput.trim()) {
      log.debug('No input received, exiting')
      process.exit(0)
    }

    try {
      input = JSON.parse(rawInput)
    } catch (e) {
      log.error('Failed to parse JSON input', { error: e.message })
      process.exit(0)
    }

    let sessionId = input.session_id
    let event = input.hook_event_name
    let toolName = input.tool_name
    let toolInput = input.tool_input
    let projectPath = input.cwd

    log.info(`Event received: ${event}`, { sessionId, event, toolName })

    if (!sessionId) {
      log.warn('No session_id in input')
      process.exit(0)
    }

    database = getDb()

    switch (event) {
      case 'PreToolUse': {
        log.info('PreToolUse: updating last tool', { sessionId, toolName })
        updateSession(database, sessionId, {
          lastTool: toolName,
          lastToolAt: new Date().toISOString(),
          workStatus: 'working',
        })

        // Check for branch creation
        let newBranch = git.detectBranchCreation(toolName, toolInput)
        if (newBranch && newBranch !== 'main' && newBranch !== 'master') {
          log.info('Branch creation detected', { newBranch })
          let repoRoot = git.getRepoRoot(projectPath) || projectPath
          let repoName = git.getRepoName(projectPath)
          let github = git.getGitHubRemote(projectPath)

          let repo = db.findOrCreateRepo(database, {
            path: repoRoot,
            name: repoName,
            githubOwner: github?.owner,
            githubName: github?.name,
          })

          let workstream = db.findWorkstreamByBranch(database, repo.id, newBranch)
          if (!workstream) {
            workstream = db.createWorkstream(database, {
              repoId: repo.id,
              branch: newBranch,
              name: branchToDisplayName(newBranch),
            })

            updateSession(database, sessionId, {
              workstreamId: workstream.id,
              branch: newBranch,
            })

            log.info('New workstream created', { workstream: workstream.name || workstream.branch })
          }
        }

        notifyApp()
        log.debug('PreToolUse: done')
        break
      }

      case 'PostToolUse': {
        log.info('PostToolUse: incrementing tool count', { sessionId, toolName })
        incrementToolCount(database, sessionId)
        notifyApp()
        log.debug('PostToolUse: done')
        break
      }

      case 'PostToolUseFailure': {
        let error = input.error
        let isInterrupt = input.is_interrupt
        log.warn('PostToolUseFailure: tool failed', { sessionId, toolName, error, isInterrupt })
        // Still increment tool count - it was attempted
        incrementToolCount(database, sessionId)
        notifyApp()
        log.debug('PostToolUseFailure: done')
        break
      }

      default:
        log.warn('Unknown event, ignoring', { event })
        break
    }
  } catch (err) {
    log.error('Hook error', { error: err.message, stack: err.stack })
  } finally {
    if (database) {
      try {
        database.close()
      } catch {}
    }
  }
}

/**
 * Convert branch name to display name
 */
let branchToDisplayName = (branch) => {
  let name = branch
    .replace(/^(feat|feature|fix|bugfix|chore|refactor|docs|test|ci)\//i, '')
    .replace(/^[A-Z]+-\d+[-_]?/i, '')

  return (
    name
      .replace(/[-_]/g, ' ')
      .replace(/\b\w/g, (c) => c.toUpperCase())
      .trim() || branch
  )
}

main()
