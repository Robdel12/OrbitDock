/**
 * Migration system tests
 */

import { mkdtempSync, writeFileSync, rmSync, mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { test, describe, beforeEach, afterEach } from 'node:test'
import assert from 'node:assert'
import Database from 'better-sqlite3'
import {
  ensureVersionTable,
  getCurrentVersion,
  getAppliedMigrations,
  parseMigrationFilename,
  getMigrationFiles,
  getPendingMigrations,
  applyMigration,
  migrate,
  needsMigration,
  getMigrationStatus,
} from './migrate.js'

describe('parseMigrationFilename', () => {
  test('parses valid migration filename', () => {
    let result = parseMigrationFilename('001_initial.sql')
    assert.deepStrictEqual(result, {
      version: 1,
      name: 'initial',
      filename: '001_initial.sql',
    })
  })

  test('parses multi-digit version', () => {
    let result = parseMigrationFilename('042_add_indexes.sql')
    assert.deepStrictEqual(result, {
      version: 42,
      name: 'add_indexes',
      filename: '042_add_indexes.sql',
    })
  })

  test('returns null for invalid filename', () => {
    assert.strictEqual(parseMigrationFilename('invalid.sql'), null)
    assert.strictEqual(parseMigrationFilename('001.sql'), null)
    assert.strictEqual(parseMigrationFilename('initial.sql'), null)
  })
})

describe('version table', () => {
  test('creates schema_versions table', () => {
    let db = new Database(':memory:')
    ensureVersionTable(db)
    let tables = db.prepare("SELECT name FROM sqlite_master WHERE type='table'").all()
    assert.ok(tables.map((t) => t.name).includes('schema_versions'))
    db.close()
  })

  test('getCurrentVersion returns 0 for empty db', () => {
    let db = new Database(':memory:')
    assert.strictEqual(getCurrentVersion(db), 0)
    db.close()
  })

  test('getAppliedMigrations returns empty array for empty db', () => {
    let db = new Database(':memory:')
    assert.deepStrictEqual(getAppliedMigrations(db), [])
    db.close()
  })
})

describe('getMigrationFiles', () => {
  test('returns sorted migrations', () => {
    let testDir = mkdtempSync(join(tmpdir(), 'migrate-test-'))
    let migrationsDir = join(testDir, 'migrations')
    mkdirSync(migrationsDir)

    writeFileSync(join(migrationsDir, '002_second.sql'), 'SELECT 1')
    writeFileSync(join(migrationsDir, '001_first.sql'), 'SELECT 1')
    writeFileSync(join(migrationsDir, '003_third.sql'), 'SELECT 1')

    let files = getMigrationFiles(migrationsDir)
    assert.deepStrictEqual(
      files.map((f) => f.version),
      [1, 2, 3]
    )
    assert.deepStrictEqual(
      files.map((f) => f.name),
      ['first', 'second', 'third']
    )

    rmSync(testDir, { recursive: true })
  })

  test('ignores non-sql files', () => {
    let testDir = mkdtempSync(join(tmpdir(), 'migrate-test-'))
    let migrationsDir = join(testDir, 'migrations')
    mkdirSync(migrationsDir)

    writeFileSync(join(migrationsDir, '001_first.sql'), 'SELECT 1')
    writeFileSync(join(migrationsDir, 'readme.md'), '# Migrations')

    let files = getMigrationFiles(migrationsDir)
    assert.strictEqual(files.length, 1)

    rmSync(testDir, { recursive: true })
  })
})

describe('migrate', () => {
  test('applies pending migrations', () => {
    let testDir = mkdtempSync(join(tmpdir(), 'migrate-test-'))
    let migrationsDir = join(testDir, 'migrations')
    mkdirSync(migrationsDir)
    let db = new Database(':memory:')

    writeFileSync(
      join(migrationsDir, '001_create_users.sql'),
      'CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)'
    )
    writeFileSync(
      join(migrationsDir, '002_add_email.sql'),
      'ALTER TABLE users ADD COLUMN email TEXT'
    )

    let applied = migrate(db, migrationsDir)

    assert.strictEqual(applied.length, 2)
    assert.strictEqual(applied[0].name, 'create_users')
    assert.strictEqual(applied[1].name, 'add_email')
    assert.strictEqual(getCurrentVersion(db), 2)

    // Verify schema was applied
    let columns = db.prepare('PRAGMA table_info(users)').all()
    assert.deepStrictEqual(
      columns.map((c) => c.name),
      ['id', 'name', 'email']
    )

    db.close()
    rmSync(testDir, { recursive: true })
  })

  test('skips already applied migrations', () => {
    let testDir = mkdtempSync(join(tmpdir(), 'migrate-test-'))
    let migrationsDir = join(testDir, 'migrations')
    mkdirSync(migrationsDir)
    let db = new Database(':memory:')

    writeFileSync(
      join(migrationsDir, '001_create_users.sql'),
      'CREATE TABLE users (id INTEGER PRIMARY KEY)'
    )
    writeFileSync(
      join(migrationsDir, '002_add_email.sql'),
      'ALTER TABLE users ADD COLUMN email TEXT'
    )

    // Run first time
    migrate(db, migrationsDir)

    // Add another migration
    writeFileSync(
      join(migrationsDir, '003_add_phone.sql'),
      'ALTER TABLE users ADD COLUMN phone TEXT'
    )

    // Run again - should only apply new one
    let applied = migrate(db, migrationsDir)
    assert.strictEqual(applied.length, 1)
    assert.strictEqual(applied[0].name, 'add_phone')

    db.close()
    rmSync(testDir, { recursive: true })
  })

  test('rolls back on failure', () => {
    let testDir = mkdtempSync(join(tmpdir(), 'migrate-test-'))
    let migrationsDir = join(testDir, 'migrations')
    mkdirSync(migrationsDir)
    let db = new Database(':memory:')

    writeFileSync(
      join(migrationsDir, '001_create_users.sql'),
      'CREATE TABLE users (id INTEGER PRIMARY KEY)'
    )
    writeFileSync(join(migrationsDir, '002_invalid.sql'), 'THIS IS NOT VALID SQL')

    // First migration should succeed, second should fail
    assert.throws(() => migrate(db, migrationsDir))

    // Version should be 1 (first succeeded, second rolled back)
    assert.strictEqual(getCurrentVersion(db), 1)

    db.close()
    rmSync(testDir, { recursive: true })
  })
})

describe('getMigrationStatus', () => {
  test('returns correct status', () => {
    let testDir = mkdtempSync(join(tmpdir(), 'migrate-test-'))
    let migrationsDir = join(testDir, 'migrations')
    mkdirSync(migrationsDir)
    let db = new Database(':memory:')

    writeFileSync(join(migrationsDir, '001_first.sql'), 'CREATE TABLE t1 (id INTEGER)')
    writeFileSync(join(migrationsDir, '002_second.sql'), 'CREATE TABLE t2 (id INTEGER)')

    // Ensure version table exists before applying migration
    ensureVersionTable(db)

    // Apply first migration only
    applyMigration(db, { version: 1, name: 'first', filename: '001_first.sql' }, migrationsDir)

    let status = getMigrationStatus(db, migrationsDir)
    assert.strictEqual(status.currentVersion, 1)
    assert.strictEqual(status.latestVersion, 2)
    assert.strictEqual(status.appliedCount, 1)
    assert.strictEqual(status.pendingCount, 1)
    assert.deepStrictEqual(status.pending, ['second'])

    db.close()
    rmSync(testDir, { recursive: true })
  })
})

describe('needsMigration', () => {
  test('returns true when migrations pending', () => {
    let testDir = mkdtempSync(join(tmpdir(), 'migrate-test-'))
    let migrationsDir = join(testDir, 'migrations')
    mkdirSync(migrationsDir)
    let db = new Database(':memory:')

    writeFileSync(join(migrationsDir, '001_first.sql'), 'SELECT 1')
    assert.strictEqual(needsMigration(db, migrationsDir), true)

    db.close()
    rmSync(testDir, { recursive: true })
  })

  test('returns false when up to date', () => {
    let testDir = mkdtempSync(join(tmpdir(), 'migrate-test-'))
    let migrationsDir = join(testDir, 'migrations')
    mkdirSync(migrationsDir)
    let db = new Database(':memory:')

    writeFileSync(join(migrationsDir, '001_first.sql'), 'SELECT 1')
    migrate(db, migrationsDir)
    assert.strictEqual(needsMigration(db, migrationsDir), false)

    db.close()
    rmSync(testDir, { recursive: true })
  })
})
