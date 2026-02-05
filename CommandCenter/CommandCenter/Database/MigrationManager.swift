//
//  MigrationManager.swift
//  OrbitDock
//
//  Database migration system - applies schema changes in order.
//  Uses embedded migrations (no external files needed).
//

import Foundation
import SQLite
import os.log

private nonisolated(unsafe) let logger = Logger(subsystem: "com.orbitdock", category: "migrations")

struct Migration: Identifiable, Sendable {
  let id: Int // version number
  let name: String
  let sql: String

  nonisolated var version: Int { id }
}

final class MigrationManager: @unchecked Sendable {
  private nonisolated(unsafe) let db: Connection

  init(db: Connection) {
    self.db = db
  }

  // MARK: - Schema Version Table

  private nonisolated func ensureVersionTable() throws {
    try db.execute("""
      CREATE TABLE IF NOT EXISTS schema_versions (
        version INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        applied_at TEXT NOT NULL
      )
    """)
  }

  nonisolated func getCurrentVersion() -> Int {
    do {
      try ensureVersionTable()
      let row = try db.scalar("SELECT MAX(version) FROM schema_versions") as? Int64
      let version = Int(row ?? 0)
      logger.debug("Current schema version: \(version)")
      return version
    } catch {
      logger.error("Failed to get schema version: \(error.localizedDescription)")
      return 0
    }
  }

  nonisolated func getAppliedMigrations() -> [(version: Int, name: String, appliedAt: String)] {
    do {
      try ensureVersionTable()
      let rows = try db.prepare("SELECT version, name, applied_at FROM schema_versions ORDER BY version")
      return rows.compactMap { row in
        guard let version = row[0] as? Int64,
              let name = row[1] as? String,
              let appliedAt = row[2] as? String
        else { return nil }
        return (Int(version), name, appliedAt)
      }
    } catch {
      logger.error("Failed to get applied migrations: \(error.localizedDescription)")
      return []
    }
  }

  // MARK: - Migration Discovery

  /// Get all available migrations from embedded sources
  nonisolated func getAvailableMigrations() -> [Migration] {
    // Use embedded migrations (always available, no external files needed)
    AppEmbeddedMigrations.all.map { Migration(id: $0.version, name: $0.name, sql: $0.sql) }
  }

  // MARK: - Migration Execution

  /// Get migrations that haven't been applied yet
  nonisolated func getPendingMigrations() -> [Migration] {
    let currentVersion = getCurrentVersion()
    return getAvailableMigrations().filter { $0.version > currentVersion }
  }

  /// Apply a single migration, handling idempotent failures gracefully
  private nonisolated func applyMigration(_ migration: Migration) throws {
    let now = ISO8601DateFormatter().string(from: Date())

    // Execute statements one at a time to handle partial schema state gracefully
    // This allows migrations to succeed even if some tables/columns already exist
    try applyMigrationStatements(migration.sql)

    // Record that it was applied
    try db.run("""
      INSERT INTO schema_versions (version, name, applied_at)
      VALUES (?, ?, ?)
    """, migration.version, migration.name, now)
  }

  /// Apply migration SQL statements individually, handling idempotent failures gracefully
  private nonisolated func applyMigrationStatements(_ sql: String) throws {
    // Split SQL into individual statements
    let statements = sql.components(separatedBy: ";")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }

    for statement in statements {
      do {
        try db.execute(statement)
      } catch {
        let errorMsg = error.localizedDescription.lowercased()

        // These errors are OK - they mean the schema already has what we're trying to add
        let isIdempotentError =
          errorMsg.contains("duplicate column name") ||
          errorMsg.contains("table") && errorMsg.contains("already exists") ||
          errorMsg.contains("index") && errorMsg.contains("already exists")

        if isIdempotentError {
          // Schema already has this, continue
          logger.debug("Migration skipped (already exists): \(statement.prefix(60))...")
        } else {
          // Real error, propagate it
          throw error
        }
      }
    }
  }

  /// Run all pending migrations
  /// Returns the list of migrations that were applied
  @discardableResult
  nonisolated func migrate() -> [Migration] {
    do {
      try ensureVersionTable()
    } catch {
      logger.error("Failed to ensure version table: \(error.localizedDescription)")
      return []
    }

    let pending = getPendingMigrations()
    if pending.isEmpty {
      logger.info("No pending migrations")
      return []
    }

    logger.info("Found \(pending.count) pending migration(s)")
    var applied: [Migration] = []

    for migration in pending {
      do {
        logger.info("Applying migration \(migration.version): \(migration.name)")
        try applyMigration(migration)
        applied.append(migration)
        logger.info("Successfully applied migration \(migration.version): \(migration.name)")
      } catch {
        logger.error("Failed to apply migration \(migration.version) (\(migration.name)): \(error.localizedDescription)")
        break // Stop on first failure
      }
    }

    if !applied.isEmpty {
      logger.info("Applied \(applied.count) migration(s). New schema version: \(self.getCurrentVersion())")
    }

    return applied
  }

  /// Check if there are pending migrations
  nonisolated func needsMigration() -> Bool {
    !getPendingMigrations().isEmpty
  }

  /// Get migration status summary
  nonisolated func getStatus() -> (current: Int, latest: Int, pending: Int) {
    let current = getCurrentVersion()
    let all = getAvailableMigrations()
    let latest = all.last?.version ?? 0
    let pending = getPendingMigrations().count
    return (current, latest, pending)
  }
}
