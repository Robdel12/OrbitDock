#!/usr/bin/env node

/**
 * Status tracker hook - tracks session work status and syncs session names
 * Handles: UserPromptSubmit, Stop, Notification
 *
 * Session naming uses three separate fields (stored independently):
 * - custom_name: User-defined via /rename command (highest display priority)
 * - summary: Claude's auto-generated title from sessions-index.json
 * - first_prompt: First user message, set once as conversation-specific fallback
 *
 * Display fallback (in Session.swift): customName → summary → firstPrompt → projectName → path
 * This ensures titles don't revert and each session has a meaningful identifier.
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
 * Get custom title from transcript (set by /rename command)
 * This is the user-defined name and should be stored in custom_name field
 * @param {string} transcriptPath - Path to the transcript file
 * @returns {string|null} - Custom title if found
 */
let getCustomTitleFromTranscript = (transcriptPath) => {
  if (!transcriptPath || !existsSync(transcriptPath)) return null

  let customTitle = null

  try {
    let content = readFileSync(transcriptPath, 'utf-8')
    let lines = content.split('\n').filter(Boolean)

    for (let line of lines) {
      try {
        let entry = JSON.parse(line)
        // Custom title from /rename - later entries override earlier ones
        if (entry.type === 'custom-title' && entry.customTitle) {
          customTitle = entry.customTitle
        }
      } catch {}
    }
  } catch (err) {
    log.debug('Failed to read transcript for custom title', { error: err.message })
  }

  return customTitle
}

/**
 * Get first user message from transcript
 * This provides a conversation-specific fallback when no title exists
 * @param {string} transcriptPath - Path to the transcript file
 * @returns {string|null} - First user message (truncated) if found
 */
let getFirstUserMessage = (transcriptPath) => {
  if (!transcriptPath || !existsSync(transcriptPath)) return null

  try {
    let content = readFileSync(transcriptPath, 'utf-8')
    let lines = content.split('\n').filter(Boolean)

    for (let line of lines) {
      try {
        let entry = JSON.parse(line)
        if (entry.type === 'user' && entry.message?.content) {
          let msg = entry.message.content
          // Skip command messages and tool results
          if (typeof msg === 'string' &&
              !msg.startsWith('<command-name>') &&
              !msg.startsWith('<local-command') &&
              !msg.includes('tool_result')) {
            // Clean and truncate
            let cleaned = msg.replace(/\s+/g, ' ').trim()
            if (cleaned.length > 80) {
              cleaned = cleaned.slice(0, 77) + '...'
            }
            if (cleaned.length > 0) {
              return cleaned
            }
          }
        }
      } catch {}
    }
  } catch (err) {
    log.debug('Failed to read transcript for first message', { error: err.message })
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

        let updates = {
          workStatus: 'waiting',
          attentionReason: attention,
        }

        // Only update custom_name if user has renamed via /rename
        // This preserves user intent and doesn't get overwritten by fallbacks
        let customTitle = getCustomTitleFromTranscript(input.transcript_path)
        if (customTitle && customTitle !== session?.custom_name) {
          updates.customName = customTitle
          log.info('Stop: found custom title', { sessionId, customTitle })
        }

        // Only update summary from Claude's sessions-index.json
        // This is Claude's generated title, separate from user's custom name
        let claudeSummary = getSessionSummaryFromIndex(input.transcript_path, sessionId)
        if (claudeSummary && claudeSummary !== session?.summary) {
          updates.summary = claudeSummary
          log.info('Stop: found Claude summary', { sessionId, claudeSummary })
        }

        // Set first_prompt once as a conversation-specific fallback
        // Only set if not already populated (never overwrite)
        if (!session?.first_prompt) {
          let firstMessage = getFirstUserMessage(input.transcript_path)
          if (firstMessage) {
            updates.firstPrompt = firstMessage
            log.info('Stop: captured first prompt', { sessionId, firstMessage })
          }
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
