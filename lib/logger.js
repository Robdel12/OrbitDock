/**
 * Simple file logger for hook debugging
 * Writes to ~/.orbitdock/hooks.log
 */

import { appendFileSync, mkdirSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

let LOG_PATH = join(homedir(), '.orbitdock', 'hooks.log')

// Ensure directory exists
try {
  mkdirSync(join(homedir(), '.orbitdock'), { recursive: true })
} catch {}

let formatTimestamp = () => {
  return new Date().toISOString()
}

let formatMessage = (level, prefix, message, data) => {
  let line = `[${formatTimestamp()}] [${level}] [${prefix}] ${message}`
  if (data !== undefined) {
    line += ` ${JSON.stringify(data)}`
  }
  return line + '\n'
}

export let createLogger = (prefix) => {
  return {
    debug: (message, data) => {
      appendFileSync(LOG_PATH, formatMessage('DEBUG', prefix, message, data))
    },
    info: (message, data) => {
      appendFileSync(LOG_PATH, formatMessage('INFO', prefix, message, data))
    },
    warn: (message, data) => {
      appendFileSync(LOG_PATH, formatMessage('WARN', prefix, message, data))
    },
    error: (message, data) => {
      appendFileSync(LOG_PATH, formatMessage('ERROR', prefix, message, data))
    },
  }
}

export { LOG_PATH as logPath }
