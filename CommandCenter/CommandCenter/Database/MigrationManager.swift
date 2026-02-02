//
//  MigrationManager.swift
//  OrbitDock
//
//  Database migration system - applies schema changes in order.
//  Migration files are bundled in the app and also live in the repo's migrations/ folder.
//

import Foundation
import SQLite
import os.log

private let logger = Logger(subsystem: "com.orbitdock", category: "migrations")

struct Migration: Identifiable {
  let id: Int // version number
  let name: String
  let sql: String

  var version: Int { id }
}

class MigrationManager {
  private let db: Connection

  init(db: Connection) {
    self.db = db
  }

  // MARK: - Schema Version Table

  private func ensureVersionTable() throws {
    try db.execute("""
      CREATE TABLE IF NOT EXISTS schema_versions (
        version INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        applied_at TEXT NOT NULL
      )
    """)
  }

  func getCurrentVersion() -> Int {
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

  func getAppliedMigrations() -> [(version: Int, name: String, appliedAt: String)] {
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

  /// Get all available migrations from bundled resources
  func getAvailableMigrations() -> [Migration] {
    var migrations: [Migration] = []

    // Look for bundled SQL files in the app bundle
    guard let resourcePath = Bundle.main.resourcePath else {
      // Fallback: try to load from the repo's migrations folder (for development)
      return loadMigrationsFromRepo()
    }

    let resourceURL = URL(fileURLWithPath: resourcePath)
    let fileManager = FileManager.default

    do {
      let files = try fileManager.contentsOfDirectory(at: resourceURL, includingPropertiesForKeys: nil)
      for file in files where file.pathExtension == "sql" {
        if let migration = parseMigrationFile(file) {
          migrations.append(migration)
        }
      }
    } catch {
      // Fallback to repo migrations
      return loadMigrationsFromRepo()
    }

    return migrations.sorted { $0.version < $1.version }
  }

  /// Load migrations from the repo's migrations/ folder (development fallback)
  private func loadMigrationsFromRepo() -> [Migration] {
    var migrations: [Migration] = []

    // Try common development paths
    let possiblePaths = [
      FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Developer/claude-dashboard/migrations"),
      URL(fileURLWithPath: #file)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("migrations"),
    ]

    for migrationsDir in possiblePaths {
      if FileManager.default.fileExists(atPath: migrationsDir.path) {
        do {
          let files = try FileManager.default.contentsOfDirectory(
            at: migrationsDir,
            includingPropertiesForKeys: nil
          )
          for file in files where file.pathExtension == "sql" {
            if let migration = parseMigrationFile(file) {
              migrations.append(migration)
            }
          }
          if !migrations.isEmpty {
            break
          }
        } catch {
          continue
        }
      }
    }

    return migrations.sorted { $0.version < $1.version }
  }

  /// Parse a migration filename like "001_initial.sql"
  private func parseMigrationFile(_ url: URL) -> Migration? {
    let filename = url.deletingPathExtension().lastPathComponent
    let pattern = #"^(\d+)_(.+)$"#

    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(
            in: filename,
            range: NSRange(filename.startIndex..., in: filename)
          ),
          let versionRange = Range(match.range(at: 1), in: filename),
          let nameRange = Range(match.range(at: 2), in: filename),
          let version = Int(filename[versionRange])
    else {
      return nil
    }

    let name = String(filename[nameRange])

    do {
      let sql = try String(contentsOf: url, encoding: .utf8)
      return Migration(id: version, name: name, sql: sql)
    } catch {
      logger.error("Failed to read migration file \(url.lastPathComponent): \(error.localizedDescription)")
      return nil
    }
  }

  // MARK: - Migration Execution

  /// Get migrations that haven't been applied yet
  func getPendingMigrations() -> [Migration] {
    let currentVersion = getCurrentVersion()
    return getAvailableMigrations().filter { $0.version > currentVersion }
  }

  /// Apply a single migration within a transaction
  private func applyMigration(_ migration: Migration) throws {
    let now = ISO8601DateFormatter().string(from: Date())

    try db.transaction {
      // Execute the migration SQL
      try db.execute(migration.sql)

      // Record that it was applied
      try db.run("""
        INSERT INTO schema_versions (version, name, applied_at)
        VALUES (?, ?, ?)
      """, migration.version, migration.name, now)
    }
  }

  /// Run all pending migrations
  /// Returns the list of migrations that were applied
  @discardableResult
  func migrate() -> [Migration] {
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
  func needsMigration() -> Bool {
    !getPendingMigrations().isEmpty
  }

  /// Get migration status summary
  func getStatus() -> (current: Int, latest: Int, pending: Int) {
    let current = getCurrentVersion()
    let all = getAvailableMigrations()
    let latest = all.last?.version ?? 0
    let pending = getPendingMigrations().count
    return (current, latest, pending)
  }
}
