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

  // Backup existing hooks
  log('📁 Backing up existing hooks...')
  let hasExistingHooks =
    existsSync(join(HOOKS_DIR, 'session-start.js')) ||
    existsSync(join(HOOKS_DIR, 'session-start.sh'))

  if (hasExistingHooks) {
    let backupDir = join(HOOKS_DIR, 'backup')
    mkdirSync(backupDir, { recursive: true })

    let files = readdirSync(HOOKS_DIR)
    for (let file of files) {
      if (file.match(/^(session-|tool-|status-).*\.(js|sh)$/)) {
        let src = join(HOOKS_DIR, file)
        let dest = join(backupDir, file)
        copyFileSync(src, dest)
      }
    }
    log(`   Backed up to ${backupDir}`)
  }

  // Copy Node.js hooks
  log('🔧 Installing hooks...')
  let hooks = ['session-start.js', 'session-end.js', 'tool-tracker.js', 'status-tracker.js']
  for (let hook of hooks) {
    copyFileSync(join(__dirname, 'hooks', hook), join(HOOKS_DIR, hook))
  }

  // Copy lib files (hooks need these)
  let libDir = join(HOOKS_DIR, 'lib')
  mkdirSync(libDir, { recursive: true })
  let libFiles = ['db.js', 'git.js', 'workstream.js']
  for (let file of libFiles) {
    copyFileSync(join(__dirname, 'lib', file), join(libDir, file))
  }

  // Update settings.json with hook configuration
  log('⚙️  Configuring hooks in settings.json...')
  let settings = {}
  if (existsSync(SETTINGS_FILE)) {
    settings = JSON.parse(readFileSync(SETTINGS_FILE, 'utf-8'))
  }

  settings.hooks = {
    SessionStart: [
      {
        hooks: [
          {
            type: 'command',
            command: `node ${join(HOOKS_DIR, 'session-start.js')}`,
            async: true,
          },
        ],
      },
    ],
    SessionEnd: [
      {
        hooks: [
          {
            type: 'command',
            command: `node ${join(HOOKS_DIR, 'session-end.js')}`,
            async: true,
          },
        ],
      },
    ],
    UserPromptSubmit: [
      {
        hooks: [
          {
            type: 'command',
            command: `node ${join(HOOKS_DIR, 'status-tracker.js')}`,
            async: true,
          },
        ],
      },
    ],
    Stop: [
      {
        hooks: [
          {
            type: 'command',
            command: `node ${join(HOOKS_DIR, 'status-tracker.js')}`,
            async: true,
          },
        ],
      },
    ],
    Notification: [
      {
        matcher: 'idle_prompt|permission_prompt',
        hooks: [
          {
            type: 'command',
            command: `node ${join(HOOKS_DIR, 'status-tracker.js')}`,
            async: true,
          },
        ],
      },
    ],
    PreToolUse: [
      {
        hooks: [
          {
            type: 'command',
            command: `node ${join(HOOKS_DIR, 'tool-tracker.js')}`,
            async: true,
          },
        ],
      },
    ],
    PostToolUse: [
      {
        hooks: [
          {
            type: 'command',
            command: `node ${join(HOOKS_DIR, 'tool-tracker.js')}`,
            async: true,
          },
        ],
      },
    ],
  }

  writeFileSync(SETTINGS_FILE, JSON.stringify(settings, null, 2))
  log('   Hooks configured in settings.json')

  // Set up MCP server
  log('🔌 Setting up MCP server...')
  let mcpConfig = { mcpServers: {} }
  if (existsSync(MCP_CONFIG)) {
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

  // Clean up old bash hooks
  let files = readdirSync(HOOKS_DIR)
  for (let file of files) {
    if (file.endsWith('.sh')) {
      rmSync(join(HOOKS_DIR, file), { force: true })
    }
  }

  // Clean up old hooks.json if it exists
  let oldHooksJson = join(HOME, '.claude', 'hooks.json')
  if (existsSync(oldHooksJson)) {
    rmSync(oldHooksJson, { force: true })
  }

  log('')
  log('✅ OrbitDock installed!')
  log('')
  log(`Hooks installed to: ${HOOKS_DIR}`)
  log('  • session-start.js')
  log('  • session-end.js')
  log('  • tool-tracker.js')
  log('  • status-tracker.js')
  log('')
  log(`MCP server configured in: ${MCP_CONFIG}`)
  log('Database location: ~/.orbitdock/orbitdock.db')
  log('')
  log('Restart Claude Code to activate.')
}

main()
