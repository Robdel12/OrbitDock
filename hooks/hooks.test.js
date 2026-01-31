import assert from 'node:assert'
import { describe, it, beforeEach, afterEach } from 'node:test'
import { spawn } from 'node:child_process'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import Database from 'better-sqlite3'
import { ensureSchema, getSession, upsertSession } from '../lib/db.js'

let __dirname = dirname(fileURLToPath(import.meta.url))

// Helper to run a hook with JSON input
let runHook = (hookName, input) => {
  return new Promise((resolve, reject) => {
    let hookPath = join(__dirname, `${hookName}.js`)
    let proc = spawn('node', [hookPath], {
      stdio: ['pipe', 'pipe', 'pipe'],
      env: { ...process.env, ORBITDOCK_DEBUG: '1' },
    })

    let stdout = ''
    let stderr = ''

    proc.stdout.on('data', (data) => {
      stdout += data.toString()
    })
    proc.stderr.on('data', (data) => {
      stderr += data.toString()
    })

    proc.on('close', (code) => {
      resolve({ code, stdout, stderr })
    })

    proc.on('error', reject)

    proc.stdin.write(JSON.stringify(input))
    proc.stdin.end()
  })
}

// Use in-memory DB for tests
let testDbPath = ':memory:'
let db

describe('status-tracker hook', () => {
  beforeEach(() => {
    db = new Database(testDbPath)
    db.pragma('journal_mode = WAL')
    ensureSchema(db)

    // Create a test session
    upsertSession(db, {
      id: 'test-session-123',
      projectPath: '/test/project',
      status: 'active',
      workStatus: 'unknown',
    })
  })

  afterEach(() => {
    db?.close()
  })

  it('handles UserPromptSubmit event', async () => {
    let result = await runHook('status-tracker', {
      session_id: 'test-session-123',
      cwd: '/test/project',
      hook_event_name: 'UserPromptSubmit',
    })

    assert.strictEqual(result.code, 0)
  })

  it('handles Stop event', async () => {
    let result = await runHook('status-tracker', {
      session_id: 'test-session-123',
      cwd: '/test/project',
      hook_event_name: 'Stop',
    })

    assert.strictEqual(result.code, 0)
  })

  it('handles Notification idle_prompt event', async () => {
    let result = await runHook('status-tracker', {
      session_id: 'test-session-123',
      cwd: '/test/project',
      hook_event_name: 'Notification',
      notification_type: 'idle_prompt',
    })

    assert.strictEqual(result.code, 0)
  })

  it('handles Notification permission_prompt event', async () => {
    let result = await runHook('status-tracker', {
      session_id: 'test-session-123',
      cwd: '/test/project',
      hook_event_name: 'Notification',
      notification_type: 'permission_prompt',
      tool_name: 'Bash',
    })

    assert.strictEqual(result.code, 0)
  })

  it('exits gracefully with no input', async () => {
    let hookPath = join(__dirname, 'status-tracker.js')
    let proc = spawn('node', [hookPath], { stdio: ['pipe', 'pipe', 'pipe'] })

    let result = await new Promise((resolve) => {
      proc.on('close', (code) => resolve({ code }))
      proc.stdin.end() // No input
    })

    assert.strictEqual(result.code, 0)
  })

  it('exits gracefully with invalid JSON', async () => {
    let hookPath = join(__dirname, 'status-tracker.js')
    let proc = spawn('node', [hookPath], { stdio: ['pipe', 'pipe', 'pipe'] })

    let result = await new Promise((resolve) => {
      proc.on('close', (code) => resolve({ code }))
      proc.stdin.write('not valid json')
      proc.stdin.end()
    })

    assert.strictEqual(result.code, 0)
  })
})

describe('tool-tracker hook', () => {
  it('handles PreToolUse event', async () => {
    let result = await runHook('tool-tracker', {
      session_id: 'test-session-456',
      cwd: '/test/project',
      hook_event_name: 'PreToolUse',
      tool_name: 'Bash',
      tool_input: { command: 'npm test' },
    })

    assert.strictEqual(result.code, 0)
  })

  it('handles PostToolUse event', async () => {
    let result = await runHook('tool-tracker', {
      session_id: 'test-session-456',
      cwd: '/test/project',
      hook_event_name: 'PostToolUse',
      tool_name: 'Bash',
    })

    assert.strictEqual(result.code, 0)
  })

  it('handles PostToolUseFailure event', async () => {
    let result = await runHook('tool-tracker', {
      session_id: 'test-session-456',
      cwd: '/test/project',
      hook_event_name: 'PostToolUseFailure',
      tool_name: 'Bash',
      error: 'Command failed with exit code 1',
      is_interrupt: false,
    })

    assert.strictEqual(result.code, 0)
  })

  it('detects branch creation in PreToolUse', async () => {
    let result = await runHook('tool-tracker', {
      session_id: 'test-session-456',
      cwd: '/tmp',
      hook_event_name: 'PreToolUse',
      tool_name: 'Bash',
      tool_input: { command: 'git checkout -b feature/new-thing' },
    })

    assert.strictEqual(result.code, 0)
  })

  it('exits gracefully with no session_id', async () => {
    let result = await runHook('tool-tracker', {
      cwd: '/test/project',
      hook_event_name: 'PreToolUse',
      tool_name: 'Bash',
    })

    assert.strictEqual(result.code, 0)
  })
})

describe('session-start hook', () => {
  it('creates a new session', async () => {
    let result = await runHook('session-start', {
      session_id: 'new-session-789',
      cwd: '/test/project',
      model: 'claude-opus-4-5-20251101',
      transcript_path: '/tmp/transcript.jsonl',
    })

    // Hook logs to file now, not stderr - just verify it ran successfully
    assert.strictEqual(result.code, 0)
  })

  it('exits gracefully with missing session_id', async () => {
    let result = await runHook('session-start', {
      cwd: '/test/project',
      model: 'claude-opus',
    })

    // Should exit with code 1 for missing required field
    assert.strictEqual(result.code, 1)
  })
})

describe('session-end hook', () => {
  it('ends a session', async () => {
    let result = await runHook('session-end', {
      session_id: 'ending-session-101',
      cwd: '/test/project',
      reason: 'logout',
    })

    // Hook logs to file now, not stderr - just verify it ran successfully
    assert.strictEqual(result.code, 0)
  })

  it('handles missing reason gracefully', async () => {
    let result = await runHook('session-end', {
      session_id: 'ending-session-102',
      cwd: '/test/project',
    })

    assert.strictEqual(result.code, 0)
  })
})
