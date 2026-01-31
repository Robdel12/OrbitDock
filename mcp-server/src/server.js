#!/usr/bin/env node

/**
 * OrbitDock MCP Server
 *
 * Exposes workstream context and management tools to Claude.
 * Production-ready with proper error handling, validation, and logging.
 */

import { Server } from '@modelcontextprotocol/sdk/server/index.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import {
  CallToolRequestSchema,
  ErrorCode,
  ListToolsRequestSchema,
  McpError,
} from '@modelcontextprotocol/sdk/types.js'

import { ensureSchema, getDb } from './db.js'
import { addWorkstreamNote, getWorkstreamContext, linkTicket } from './workstream.js'

// ============================================================================
// Configuration
// ============================================================================

const VERSION = '1.0.0'
const LOG_PREFIX = '[OrbitDock]'

// Get project path from environment or current directory
const getProjectPath = () => {
  return process.env.ORBITDOCK_PROJECT_PATH || process.cwd()
}

// ============================================================================
// Logging
// ============================================================================

const log = {
  info: (msg, data) => console.error(`${LOG_PREFIX} ${msg}`, data ? JSON.stringify(data) : ''),
  error: (msg, err) => console.error(`${LOG_PREFIX} ERROR: ${msg}`, err?.message || err),
  debug: (msg, data) => {
    if (process.env.ORBITDOCK_DEBUG) {
      console.error(`${LOG_PREFIX} DEBUG: ${msg}`, data ? JSON.stringify(data) : '')
    }
  },
}

// ============================================================================
// Tool Definitions
// ============================================================================

const TOOLS = [
  {
    name: 'get_workstream_context',
    description: `Get context about the current workstream you're working on.

Returns:
- Workstream name, branch, and stage
- Linked tickets (Linear issues, GitHub issues/PRs)
- Recent notes, decisions, and blockers
- Session history and commit stats

Use this at the start of a session to understand what you're working on,
or when you need to recall previous decisions and context.

Returns hasWorkstream: false if you're on main/master branch.`,
    inputSchema: {
      type: 'object',
      properties: {},
      required: [],
    },
  },
  {
    name: 'add_workstream_note',
    description: `Add a note to the current workstream.

Use this to document:
- **decision**: Important technical decisions ("Using Redis for caching because...")
- **blocker**: Something blocking progress ("Waiting on API access from...")
- **pivot**: Change in approach ("Switching from REST to GraphQL because...")
- **milestone**: Significant progress ("Auth system complete and tested")
- **note**: General observations or context

Notes persist across sessions, helping future you (or other agents) understand
the journey and reasoning behind the implementation.

Fails if not on a feature branch (no workstream).`,
    inputSchema: {
      type: 'object',
      properties: {
        type: {
          type: 'string',
          enum: ['note', 'decision', 'blocker', 'pivot', 'milestone'],
          description: 'Type of note',
        },
        content: {
          type: 'string',
          description: 'The note content (required, non-empty)',
        },
      },
      required: ['type', 'content'],
    },
  },
  {
    name: 'link_ticket',
    description: `Link a ticket (Linear issue, GitHub issue, or GitHub PR) to the current workstream.

This helps track which tickets are being addressed by this workstream.
Mark one ticket as "primary" to indicate the main deliverable.

Fails if not on a feature branch (no workstream).`,
    inputSchema: {
      type: 'object',
      properties: {
        source: {
          type: 'string',
          enum: ['linear', 'github_issue', 'github_pr'],
          description: 'Where the ticket comes from',
        },
        external_id: {
          type: 'string',
          description: 'The ticket ID (e.g., "VIZ-123" or "456")',
        },
        title: {
          type: 'string',
          description: 'Ticket title (optional)',
        },
        state: {
          type: 'string',
          description: 'Current state (optional, e.g., "In Progress", "Open")',
        },
        url: {
          type: 'string',
          description: 'URL to the ticket (optional)',
        },
        is_primary: {
          type: 'boolean',
          description: 'Whether this is the primary ticket for this workstream (default: false)',
        },
      },
      required: ['source', 'external_id'],
    },
  },
]

// ============================================================================
// Validation Helpers
// ============================================================================

const validateNoteInput = (args) => {
  if (!args.type || !['note', 'decision', 'blocker', 'pivot', 'milestone'].includes(args.type)) {
    throw new McpError(
      ErrorCode.InvalidParams,
      `Invalid note type: ${args.type}. Must be one of: note, decision, blocker, pivot, milestone`,
    )
  }
  if (!args.content || typeof args.content !== 'string' || args.content.trim().length === 0) {
    throw new McpError(ErrorCode.InvalidParams, 'Note content is required and must be non-empty')
  }
}

const validateTicketInput = (args) => {
  if (!args.source || !['linear', 'github_issue', 'github_pr'].includes(args.source)) {
    throw new McpError(
      ErrorCode.InvalidParams,
      `Invalid ticket source: ${args.source}. Must be one of: linear, github_issue, github_pr`,
    )
  }
  if (
    !args.external_id ||
    typeof args.external_id !== 'string' ||
    args.external_id.trim().length === 0
  ) {
    throw new McpError(
      ErrorCode.InvalidParams,
      'Ticket external_id is required and must be non-empty',
    )
  }
}

// ============================================================================
// Tool Handlers
// ============================================================================

const handleGetWorkstreamContext = (db, projectPath) => {
  log.debug('get_workstream_context', { projectPath })

  const context = getWorkstreamContext(db, projectPath)

  // Format response based on whether workstream exists
  if (!context.hasWorkstream) {
    return {
      content: [
        {
          type: 'text',
          text: `No active workstream. You're on branch "${context.branch || 'unknown'}" which appears to be a main branch.\n\nWorkstreams are created automatically when you create a feature branch (git checkout -b, git switch -c, etc.).`,
        },
      ],
    }
  }

  return {
    content: [
      {
        type: 'text',
        text: JSON.stringify(context, null, 2),
      },
    ],
  }
}

const handleAddNote = (db, projectPath, args) => {
  validateNoteInput(args)
  log.debug('add_workstream_note', { projectPath, type: args.type })

  try {
    const note = addWorkstreamNote(db, projectPath, {
      type: args.type,
      content: args.content.trim(),
    })

    log.info(`Note added: [${note.type}]`)

    return {
      content: [
        {
          type: 'text',
          text: `✓ Note added to workstream\n\nType: ${note.type}\nContent: ${note.content}`,
        },
      ],
    }
  } catch (err) {
    if (err.message.includes('No active workstream')) {
      throw new McpError(
        ErrorCode.InvalidRequest,
        'Cannot add note: No active workstream. You must be on a feature branch.',
      )
    }
    throw err
  }
}

const handleLinkTicket = (db, projectPath, args) => {
  validateTicketInput(args)
  log.debug('link_ticket', { projectPath, source: args.source, id: args.external_id })

  try {
    const ticket = linkTicket(db, projectPath, {
      source: args.source,
      externalId: args.external_id.trim(),
      title: args.title?.trim(),
      state: args.state?.trim(),
      url: args.url?.trim(),
      isPrimary: Boolean(args.is_primary),
    })

    log.info(`Ticket linked: ${ticket.source}:${ticket.external_id}`)

    const primaryNote = ticket.is_primary ? ' (marked as primary)' : ''
    return {
      content: [
        {
          type: 'text',
          text: `✓ Ticket linked to workstream${primaryNote}\n\nSource: ${ticket.source}\nID: ${ticket.external_id}${ticket.title ? `\nTitle: ${ticket.title}` : ''}${ticket.url ? `\nURL: ${ticket.url}` : ''}`,
        },
      ],
    }
  } catch (err) {
    if (err.message.includes('No active workstream')) {
      throw new McpError(
        ErrorCode.InvalidRequest,
        'Cannot link ticket: No active workstream. You must be on a feature branch.',
      )
    }
    throw err
  }
}

// ============================================================================
// Server Setup
// ============================================================================

const server = new Server(
  {
    name: 'orbitdock',
    version: VERSION,
    description:
      "Workstream context and management for Claude Code sessions. Tracks what you're working on across sessions, linked tickets, and decisions made along the way.",
  },
  {
    capabilities: {
      tools: {},
    },
  },
)

// List tools handler
server.setRequestHandler(ListToolsRequestSchema, async () => {
  log.debug('ListTools request')
  return { tools: TOOLS }
})

// Call tool handler
server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args = {} } = request.params

  log.debug(`Tool call: ${name}`, args)

  let db
  try {
    db = getDb()
    ensureSchema(db)

    const projectPath = getProjectPath()

    switch (name) {
      case 'get_workstream_context':
        return handleGetWorkstreamContext(db, projectPath)

      case 'add_workstream_note':
        return handleAddNote(db, projectPath, args)

      case 'link_ticket':
        return handleLinkTicket(db, projectPath, args)

      default:
        throw new McpError(ErrorCode.MethodNotFound, `Unknown tool: ${name}`)
    }
  } catch (err) {
    // Re-throw MCP errors as-is
    if (err instanceof McpError) {
      throw err
    }

    // Wrap unexpected errors
    log.error(`Tool ${name} failed`, err)
    throw new McpError(ErrorCode.InternalError, `Tool execution failed: ${err.message}`)
  } finally {
    if (db) {
      try {
        db.close()
      } catch (closeErr) {
        log.error('Failed to close database', closeErr)
      }
    }
  }
})

// ============================================================================
// Startup & Shutdown
// ============================================================================

let transport

const shutdown = async (signal) => {
  log.info(`Received ${signal}, shutting down...`)
  try {
    if (transport) {
      await server.close()
    }
    process.exit(0)
  } catch (err) {
    log.error('Shutdown error', err)
    process.exit(1)
  }
}

// Handle graceful shutdown
process.on('SIGINT', () => shutdown('SIGINT'))
process.on('SIGTERM', () => shutdown('SIGTERM'))

// Handle uncaught errors
process.on('uncaughtException', (err) => {
  log.error('Uncaught exception', err)
  process.exit(1)
})

process.on('unhandledRejection', (reason) => {
  log.error('Unhandled rejection', reason)
  process.exit(1)
})

// Start server
const main = async () => {
  try {
    // Ensure database is accessible on startup
    const db = getDb()
    ensureSchema(db)
    db.close()
    log.info('Database initialized')

    transport = new StdioServerTransport()
    await server.connect(transport)
    log.info(`MCP server v${VERSION} started`, { projectPath: getProjectPath() })
  } catch (err) {
    log.error('Failed to start server', err)
    process.exit(1)
  }
}

main()
