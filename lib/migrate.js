/**
 * Database migration system
 *
 * Manages schema versions and applies migrations in order.
 * Migration files live in ../migrations/ as numbered SQL files.
 */

import { readdirSync, readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

let __dirname = dirname(fileURLToPath(import.meta.url))
let MIGRATIONS_DIR = join(__dirname, '..', 'migrations')

/**
 * Ensure the schema_versions table exists
 */
export let ensureVersionTable = (db) => {
  db.exec(`
    CREATE TABLE IF NOT EXISTS schema_versions (
      version INTEGER PRIMARY KEY,
      name TEXT NOT NULL,
      applied_at TEXT NOT NULL
    )
  `)
}

/**
 * Get the current schema version (highest applied migration)
 */
export let getCurrentVersion = (db) => {
  ensureVersionTable(db)
  let row = db.prepare('SELECT MAX(version) as version FROM schema_versions').get()
  return row?.version || 0
}

/**
 * Get list of applied migrations
 */
export let getAppliedMigrations = (db) => {
  ensureVersionTable(db)
  return db.prepare('SELECT * FROM schema_versions ORDER BY version').all()
}

/**
 * Parse migration filename to get version and name
 * e.g., "001_initial.sql" -> { version: 1, name: "initial" }
 */
export let parseMigrationFilename = (filename) => {
  let match = filename.match(/^(\d+)_(.+)\.sql$/)
  if (!match) return null
  return {
    version: parseInt(match[1], 10),
    name: match[2],
    filename,
  }
}

/**
 * Get all migration files sorted by version
 */
export let getMigrationFiles = (migrationsDir = MIGRATIONS_DIR) => {
  let files = readdirSync(migrationsDir)
    .filter((f) => f.endsWith('.sql'))
    .map(parseMigrationFilename)
    .filter(Boolean)
    .sort((a, b) => a.version - b.version)

  return files
}

/**
 * Get pending migrations (not yet applied)
 */
export let getPendingMigrations = (db, migrationsDir = MIGRATIONS_DIR) => {
  let currentVersion = getCurrentVersion(db)
  let allMigrations = getMigrationFiles(migrationsDir)
  return allMigrations.filter((m) => m.version > currentVersion)
}

/**
 * Apply a single migration
 */
export let applyMigration = (db, migration, migrationsDir = MIGRATIONS_DIR) => {
  let sqlPath = join(migrationsDir, migration.filename)
  let sql = readFileSync(sqlPath, 'utf-8')

  // Run migration in a transaction
  db.exec('BEGIN TRANSACTION')
  try {
    db.exec(sql)
    db.prepare(`
      INSERT INTO schema_versions (version, name, applied_at)
      VALUES (?, ?, datetime('now'))
    `).run(migration.version, migration.name)
    db.exec('COMMIT')
    return true
  } catch (err) {
    db.exec('ROLLBACK')
    throw err
  }
}

/**
 * Run all pending migrations
 * Returns array of applied migration names
 */
export let migrate = (db, migrationsDir = MIGRATIONS_DIR) => {
  ensureVersionTable(db)

  let pending = getPendingMigrations(db, migrationsDir)
  let applied = []

  for (let migration of pending) {
    applyMigration(db, migration, migrationsDir)
    applied.push(migration)
  }

  return applied
}

/**
 * Check if database needs migrations
 */
export let needsMigration = (db, migrationsDir = MIGRATIONS_DIR) => {
  return getPendingMigrations(db, migrationsDir).length > 0
}

/**
 * Get migration status summary
 */
export let getMigrationStatus = (db, migrationsDir = MIGRATIONS_DIR) => {
  let current = getCurrentVersion(db)
  let all = getMigrationFiles(migrationsDir)
  let pending = getPendingMigrations(db, migrationsDir)
  let applied = getAppliedMigrations(db)

  return {
    currentVersion: current,
    latestVersion: all.length > 0 ? all[all.length - 1].version : 0,
    appliedCount: applied.length,
    pendingCount: pending.length,
    pending: pending.map((m) => m.name),
    applied: applied.map((m) => ({ version: m.version, name: m.name, appliedAt: m.applied_at })),
  }
}
