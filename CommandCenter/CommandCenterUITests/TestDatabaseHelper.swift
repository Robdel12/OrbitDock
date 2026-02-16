//
//  TestDatabaseHelper.swift
//  CommandCenterUITests
//
//  Manages test database setup and teardown for UI tests
//

import Foundation

enum TestDatabaseHelper {
  static let testDbPath = "/tmp/orbitdock-uitest.db"

  /// Set up a fresh test database with seed data
  static func setupTestDatabase() {
    // Remove any existing test database
    try? FileManager.default.removeItem(atPath: testDbPath)
    try? FileManager.default.removeItem(atPath: "\(testDbPath)-wal")
    try? FileManager.default.removeItem(atPath: "\(testDbPath)-shm")

    // Get path to migrations and seed data
    let bundle = Bundle(for: BundleLocator.self)
    let projectRoot = findProjectRoot()

    // Run migrations
    let migrationsPath = projectRoot.appendingPathComponent("migrations")
    runMigrations(dbPath: testDbPath, migrationsDir: migrationsPath)

    // Run seed data
    if let seedPath = bundle.path(forResource: "seed_data", ofType: "sql") {
      runSQL(dbPath: testDbPath, sqlFile: URL(fileURLWithPath: seedPath))
    } else {
      // Fallback: try from fixtures directory
      let fixturesPath = projectRoot
        .appendingPathComponent("CommandCenter/CommandCenterUITests/Fixtures/seed_data.sql")
      if FileManager.default.fileExists(atPath: fixturesPath.path) {
        runSQL(dbPath: testDbPath, sqlFile: fixturesPath)
      }
    }
  }

  /// Clean up the test database
  static func teardownTestDatabase() {
    try? FileManager.default.removeItem(atPath: testDbPath)
    try? FileManager.default.removeItem(atPath: "\(testDbPath)-wal")
    try? FileManager.default.removeItem(atPath: "\(testDbPath)-shm")
  }

  private static func findProjectRoot() -> URL {
    // Walk up from the test bundle to find the project root
    var url = Bundle(for: BundleLocator.self).bundleURL

    // Look for the migrations directory
    for _ in 0 ..< 10 {
      let migrationsPath = url.appendingPathComponent("migrations")
      if FileManager.default.fileExists(atPath: migrationsPath.path) {
        return url
      }
      url = url.deletingLastPathComponent()
    }

    // Fallback to known path
    return URL(fileURLWithPath: "/Users/robertdeluca/Developer/claude-dashboard")
  }

  private static func runMigrations(dbPath: String, migrationsDir: URL) {
    guard let files = try? FileManager.default.contentsOfDirectory(
      at: migrationsDir,
      includingPropertiesForKeys: nil
    ) else { return }

    let sqlFiles = files
      .filter { $0.pathExtension == "sql" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }

    for sqlFile in sqlFiles {
      runSQL(dbPath: dbPath, sqlFile: sqlFile)
    }
  }

  private static func runSQL(dbPath: String, sqlFile: URL) {
    guard let sql = try? String(contentsOf: sqlFile, encoding: .utf8) else { return }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [dbPath]

    let pipe = Pipe()
    process.standardInput = pipe
    process.standardError = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice

    do {
      try process.run()
      pipe.fileHandleForWriting.write(sql.data(using: .utf8)!)
      pipe.fileHandleForWriting.closeFile()
      process.waitUntilExit()
    } catch {
      print("Failed to run SQL: \(error)")
    }
  }
}

/// Helper class to locate the test bundle
private class BundleLocator {}
