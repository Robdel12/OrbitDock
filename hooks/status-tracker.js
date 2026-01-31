#!/usr/bin/env node

/**
 * Status tracker hook - tracks session work status and syncs session names
 * Handles: UserPromptSubmit, Stop, Notification
 *
 * On Stop events, resolves the best session title from multiple sources:
 * 1. Custom title (user's /rename command) - highest priority
 * 2. Claude's summary from sessions-index.json
 * 3. First user message (truncated) - fallback
 * 4. Session slug - last resort
 *
 * Input (stdin JSON):
 * {
 *   "session_id": "abc-123",
 *   "cwd": "/path/to/project",
 *   "transcript_path": "/path/to/transcript.jsonl",
 *   "hook_event_name": "UserPromptSubmit" | "Stop" | "Notification",
 *   "notification_type": "idle_prompt" | "permission_prompt",
 *   "tool_name": "Bash" (for permission_prompt)
 * }
 */

import { readFileSync, existsSync } from 'node:fs'
import { execSync } from 'node:child_process'
import { dirname, join } from 'node:path'
import { getDb, updateSession, incrementPromptCount, getSession } from '../lib/db.js'
import { createLogger } from '../lib/logger.js'

let log = createLogger('status-tracker')

/**
 * Resolve the best session title from multiple sources
 * Priority: custom-title > sessions-index summary > first user message > slug
 * @param {string} transcriptPath - Path to the transcript file
 * @param {string} sessionId - Session ID to look up
 * @returns {string|null} - Best available title
 */
let resolveSessionTitle = (transcriptPath, sessionId) => {
  if (!transcriptPath || !existsSync(transcriptPath)) return null

  let customTitle = null
  let firstUserMessage = null
  let slug = null

  try {
    // Read transcript line by line to find title sources
    let content = readFileSync(transcriptPath, 'utf-8')
    let lines = content.split('\n').filter(Boolean)

    for (let line of lines) {
      try {
        let entry = JSON.parse(line)

        // Priority 1: Custom title from /rename
        if (entry.type === 'custom-title' && entry.customTitle) {
          customTitle = entry.customTitle
          // Don't break - later custom-title entries override earlier ones
        }

        // Capture slug from any entry (they all have it)
        if (!slug && entry.slug) {
          slug = entry.slug
        }

        // Capture first user message (that's actual content, not commands)
        if (!firstUserMessage && entry.type === 'user' && entry.message?.content) {
          let content = entry.message.content
          // Skip command messages and tool results
          if (typeof content === 'string' &&
              !content.startsWith('<command-name>') &&
              !content.startsWith('<local-command') &&
              !content.includes('tool_result')) {
            // Clean and truncate
            let cleaned = content.replace(/\s+/g, ' ').trim()
            if (cleaned.length > 60) {
              cleaned = cleaned.slice(0, 57) + '...'
            }
            if (cleaned.length > 0) {
              firstUserMessage = cleaned
            }
          }
        }
      } catch {}
    }
  } catch (err) {
    log.debug('Failed to read transcript for title', { error: err.message })
  }

  // Priority 1: Custom title
  if (customTitle) {
    log.debug('Using custom title', { customTitle })
    return customTitle
  }

  // Priority 2: Claude's summary from sessions-index.json
  let summary = getSessionSummaryFromIndex(transcriptPath, sessionId)
  if (summary) {
    log.debug('Using sessions-index summary', { summary })
    return summary
  }

  // Priority 3: First user message
  if (firstUserMessage) {
    log.debug('Using first user message', { firstUserMessage })
    return firstUserMessage
  }

  // Priority 4: Slug (humanize it)
  if (slug) {
    let humanized = slug.split('-').map(w => w.charAt(0).toUpperCase() + w.slice(1)).join(' ')
    log.debug('Using humanized slug', { slug, humanized })
    return humanized
  }

  return null
}

/**
 * Get session summary from Claude's sessions-index.json
 * @param {string} transcriptPath - Path to the transcript file
 * @param {string} sessionId - Session ID to look up
 * @returns {string|null} - Summary if found
 */
let getSessionSummaryFromIndex = (transcriptPath, sessionId) => {
  if (!transcriptPath) return null

  let projectDir = dirname(transcriptPath)
  let indexPath = join(projectDir, 'sessions-index.json')

  if (!existsSync(indexPath)) {
    return null
  }

  try {
    let data = JSON.parse(readFileSync(indexPath, 'utf-8'))
    let entries = data.entries || []
    let entry = entries.find((e) => e.sessionId === sessionId)
    return entry?.summary || null
  } catch {
    return null
  }
}

let notifyApp = () => {
  try {
    execSync('notifyutil -p com.orbitdock.session.updated', { stdio: 'ignore' })
  } catch {}
}

let main = () => {
  let input
  let db

  try {
    let rawInput = readFileSync(0, 'utf-8')
    if (!rawInput.trim()) {
      log.debug('No input received, exiting')
      process.exit(0)
    }

    try {
      input = JSON.parse(rawInput)
    } catch (e) {
      log.error('Failed to parse JSON input', { error: e.message, raw: rawInput.slice(0, 200) })
      process.exit(0)
    }

    let sessionId = input.session_id
    let event = input.hook_event_name

    log.info(`Event received: ${event}`, {
      sessionId,
      event,
      notifType: input.notification_type,
      transcriptPath: input.transcript_path,
    })

    if (!sessionId) {
      log.warn('No session_id in input')
      process.exit(0)
    }

    db = getDb()

    switch (event) {
      case 'UserPromptSubmit': {
        log.info('UserPromptSubmit: incrementing prompt count', { sessionId })
        incrementPromptCount(db, sessionId)
        updateSession(db, sessionId, {
          workStatus: 'working',
          attentionReason: 'none',
          pendingToolName: null,
          pendingQuestion: null,
        })
        notifyApp()
        log.debug('UserPromptSubmit: done')
        break
      }

      case 'Stop': {
        let session = getSession(db, sessionId)
        let attention = session?.last_tool === 'AskUserQuestion' ? 'awaitingQuestion' : 'awaitingReply'

        // Resolve best available title for the session
        let title = resolveSessionTitle(input.transcript_path, sessionId)
        let updates = {
          workStatus: 'waiting',
          attentionReason: attention,
        }
        if (title) {
          updates.summary = title
          log.info('Stop: resolved title', { sessionId, title })
        }

        log.info('Stop: setting waiting status', { sessionId, attention, lastTool: session?.last_tool })
        updateSession(db, sessionId, updates)
        notifyApp()
        log.debug('Stop: done')
        break
      }

      case 'Notification': {
        let notifType = input.notification_type
        let toolName = input.tool_name

        log.info('Notification received', { sessionId, notifType, toolName })

        if (notifType === 'idle_prompt') {
          let session = getSession(db, sessionId)
          let attention = session?.last_tool === 'AskUserQuestion' ? 'awaitingQuestion' : 'awaitingReply'

          updateSession(db, sessionId, {
            workStatus: 'waiting',
            attentionReason: attention,
          })
          notifyApp()
          log.debug('Notification idle_prompt: done')
        } else if (notifType === 'permission_prompt') {
          updateSession(db, sessionId, {
            workStatus: 'permission',
            attentionReason: 'awaitingPermission',
            pendingToolName: toolName || null,
          })
          notifyApp()
          log.debug('Notification permission_prompt: done')
        }
        break
      }

      default:
        log.warn('Unknown event, ignoring', { event })
        break
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
