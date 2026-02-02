#!/usr/bin/env node

/**
 * Database migration CLI
 *
 * Usage:
 *   ./scripts/migrate.js          # Run pending migrations
 *   ./scripts/migrate.js status   # Show migration status
 *   ./scripts/migrate.js list     # List all migrations
 */

import { getDb } from '../lib/db.js'
import {
  migrate,
  getMigrationStatus,
  getMigrationFiles,
  getAppliedMigrations,
} from '../lib/migrate.js'

let command = process.argv[2] || 'run'

let db = getDb()

try {
  switch (command) {
    case 'run': {
      console.log('Running migrations...\n')
      let applied = migrate(db)
      if (applied.length === 0) {
        console.log('✓ Database is up to date')
      } else {
        console.log(`\n✓ Applied ${applied.length} migration(s)`)
      }
      break
    }

    case 'status': {
      let status = getMigrationStatus(db)
      console.log('Migration Status')
      console.log('================')
      console.log(`Current version: ${status.currentVersion}`)
      console.log(`Latest version:  ${status.latestVersion}`)
      console.log(`Applied:         ${status.appliedCount}`)
      console.log(`Pending:         ${status.pendingCount}`)

      if (status.pending.length > 0) {
        console.log('\nPending migrations:')
        status.pending.forEach((name) => console.log(`  - ${name}`))
      }
      break
    }

    case 'list': {
      let all = getMigrationFiles()
      let applied = getAppliedMigrations(db)
      let appliedVersions = new Set(applied.map((m) => m.version))

      console.log('All Migrations')
      console.log('==============')
      all.forEach((m) => {
        let status = appliedVersions.has(m.version) ? '✓' : '○'
        let appliedInfo = applied.find((a) => a.version === m.version)
        let date = appliedInfo ? ` (${appliedInfo.applied_at})` : ''
        console.log(`${status} ${String(m.version).padStart(3, '0')}_${m.name}${date}`)
      })
      break
    }

    case 'help':
    default:
      console.log(`
Database Migration CLI

Usage:
  ./scripts/migrate.js [command]

Commands:
  run      Run pending migrations (default)
  status   Show migration status
  list     List all migrations with their status
  help     Show this help message
`)
  }
} finally {
  db.close()
}
