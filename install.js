#!/usr/bin/env node

/**
 * OrbitDock Installer
 * Sets up hooks and MCP server configuration for Claude Code
 */

import { execSync } from 'node:child_process'
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const HOME = process.env.HOME
const HOOKS_DIR = join(HOME, '.claude', 'hooks')
const SETTINGS_FILE = join(HOME, '.claude', 'settings.json')
const MCP_CONFIG = join(HOME, '.claude', 'mcp.json')

const log = (msg) => console.log(msg)

const main = () => {
  log('🚀 Installing OrbitDock...')

  // Ensure directories exist
  mkdirSync(HOOKS_DIR, { recursive: true })
  mkdirSync(join(HOME, '.orbitdock'), { recursive: true })

  // Install npm dependencies
  log('📦 Installing dependencies...')
  execSync('npm install', { cwd: __dirname, stdio: 'inherit' })

  // Clean up old copied hooks (we now run from repo directly)
  log('🧹 Cleaning up old hooks...')
  let oldHookFiles = ['session-start.js', 'session-end.js', 'tool-tracker.js', 'status-tracker.js']
  for (let hook of oldHookFiles) {
    let hookPath = join(HOOKS_DIR, hook)
    if (existsSync(hookPath)) {
      rmSync(hookPath, { force: true })
    }
  }
  // Clean up old lib dir if it exists
  let oldLibDir = join(HOOKS_DIR, 'lib')
  if (existsSync(oldLibDir)) {
    rmSync(oldLibDir, { recursive: true, force: true })
  }
  // Clean up old bash hooks
  if (existsSync(HOOKS_DIR)) {
    let files = readdirSync(HOOKS_DIR)
    for (let file of files) {
      if (file.endsWith('.sh')) {
        rmSync(join(HOOKS_DIR, file), { force: true })
      }
    }
  }

  // Update settings.json with hook configuration
  log('⚙️  Configuring hooks in settings.json...')
  let settings = {}
  if (existsSync(SETTINGS_FILE)) {
    // Backup settings.json before modifying
    let backupPath = `${SETTINGS_FILE}.backup`
    copyFileSync(SETTINGS_FILE, backupPath)
    log(`   Backed up settings.json to ${backupPath}`)
    settings = JSON.parse(readFileSync(SETTINGS_FILE, 'utf-8'))
  }

  // OrbitDock hook definitions (run from repo, not copied)
  // All hooks use async: true since we're tracking telemetry, not blocking actions
  let hooksPath = join(__dirname, 'hooks')
  let orbitdockHooks = {
    SessionStart: {
      hooks: [
        {
          type: 'command',
          command: `node ${join(hooksPath, 'session-start.js')}`,
          async: true,
        },
      ],
    },
    SessionEnd: {
      hooks: [
        {
          type: 'command',
          command: `node ${join(hooksPath, 'session-end.js')}`,
          async: true,
        },
      ],
    },
    UserPromptSubmit: {
      hooks: [
        {
          type: 'command',
          command: `node ${join(hooksPath, 'status-tracker.js')}`,
          async: true,
        },
      ],
    },
    Stop: {
      hooks: [
        {
          type: 'command',
          command: `node ${join(hooksPath, 'status-tracker.js')}`,
          async: true,
        },
      ],
    },
    Notification: {
      matcher: 'idle_prompt|permission_prompt',
      hooks: [
        {
          type: 'command',
          command: `node ${join(hooksPath, 'status-tracker.js')}`,
          async: true,
        },
      ],
    },
    PreToolUse: {
      hooks: [
        {
          type: 'command',
          command: `node ${join(hooksPath, 'tool-tracker.js')}`,
          async: true,
        },
      ],
    },
    PostToolUse: {
      hooks: [
        {
          type: 'command',
          command: `node ${join(hooksPath, 'tool-tracker.js')}`,
          async: true,
        },
      ],
    },
    PostToolUseFailure: {
      hooks: [
        {
          type: 'command',
          command: `node ${join(hooksPath, 'tool-tracker.js')}`,
          async: true,
        },
      ],
    },
  }

  // Merge with existing hooks (preserve user's other hooks)
  settings.hooks = settings.hooks || {}

  for (let [event, hookConfig] of Object.entries(orbitdockHooks)) {
    let existing = settings.hooks[event] || []

    // Remove any previous OrbitDock hooks (by command path patterns)
    existing = existing.filter((entry) => {
      let commands = entry.hooks?.map((h) => h.command) || []
      return !commands.some((cmd) =>
        cmd?.includes('.claude/hooks/') ||
        cmd?.includes('claude-dashboard/hooks/') ||
        cmd?.includes('orbitdock/hooks/')
      )
    })

    // Add OrbitDock hook
    existing.push(hookConfig)
    settings.hooks[event] = existing
  }

  writeFileSync(SETTINGS_FILE, JSON.stringify(settings, null, 2))
  log('   Hooks configured in settings.json')

  // Set up MCP server
  log('🔌 Setting up MCP server...')
  let mcpConfig = { mcpServers: {} }
  if (existsSync(MCP_CONFIG)) {
    // Backup mcp.json before modifying
    let backupPath = `${MCP_CONFIG}.backup`
    copyFileSync(MCP_CONFIG, backupPath)
    log(`   Backed up mcp.json to ${backupPath}`)
    mcpConfig = JSON.parse(readFileSync(MCP_CONFIG, 'utf-8'))
  }

  mcpConfig.mcpServers = mcpConfig.mcpServers || {}
  mcpConfig.mcpServers.orbitdock = {
    command: 'node',
    args: [join(__dirname, 'mcp-server', 'server.js')],
    env: {},
  }

  writeFileSync(MCP_CONFIG, JSON.stringify(mcpConfig, null, 2))
  log('   MCP server configured')

  // Clean up old hooks.json if it exists
  let oldHooksJson = join(HOME, '.claude', 'hooks.json')
  if (existsSync(oldHooksJson)) {
    rmSync(oldHooksJson, { force: true })
  }

  log('')
  log('✅ OrbitDock installed!')
  log('')
  log(`Hooks configured in: ${SETTINGS_FILE}`)
  log(`  → Running from: ${join(__dirname, 'hooks')}`)
  log('')
  log(`MCP server configured in: ${MCP_CONFIG}`)
  log(`  → Running from: ${join(__dirname, 'mcp-server')}`)
  log('')
  log('Database location: ~/.orbitdock/orbitdock.db')
  log('')
  log('Restart Claude Code to activate.')
}

main()
