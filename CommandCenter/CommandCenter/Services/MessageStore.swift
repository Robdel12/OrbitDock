//
//  MessageStore.swift
//  OrbitDock
//
//  SQLite-backed message storage for fast reads/writes.
//

import Foundation
import SQLite

/// High-performance message store using SQLite
/// Uses separate read/write connections for non-blocking reads
final class MessageStore {
  static let shared = MessageStore()

  // Separate connections for concurrent read/write
  private var writeDb: Connection? // For syncs (exclusive writes)
  private var readDb: Connection? // For UI reads (never blocks on writes)
  private let dbPath: String

  // Prevent concurrent syncs for the same session
  private var syncLocks: [String: NSLock] = [:]
  private let syncLocksMeta = NSLock()

  // Table definitions
  private let messages = Table("messages")
  private let id = SQLite.Expression<String>("id")
  private let sessionId = SQLite.Expression<String>("session_id")
  private let type = SQLite.Expression<String>("type")
  private let content = SQLite.Expression<String>("content")
  private let timestamp = SQLite.Expression<Date>("timestamp")
  private let sequence = SQLite.Expression<Int>("sequence") // Preserves JSONL order
  private let toolName = SQLite.Expression<String?>("tool_name")
  private let toolInput = SQLite.Expression<String?>("tool_input") // JSON string
  private let toolOutput = SQLite.Expression<String?>("tool_output")
  private let toolDuration = SQLite.Expression<Double?>("tool_duration") // Seconds
  private let isInProgress = SQLite.Expression<Int>("is_in_progress")
  private let inputTokens = SQLite.Expression<Int?>("input_tokens")
  private let outputTokens = SQLite.Expression<Int?>("output_tokens")
  private let imageData = SQLite.Expression<Data?>("image_data") // Legacy single image
  private let imageMimeType = SQLite.Expression<String?>("image_mime_type") // Legacy
  private let imagesJson = SQLite.Expression<String?>("images_json") // JSON array of {data: base64, mimeType: string}
  private let thinking = SQLite.Expression<String?>("thinking") // Claude's thinking trace

  // Stats table for aggregated message data (separate from main session_stats)
  private let sessionStats = Table("message_session_stats")
  private let statsSessionId = SQLite.Expression<String>("session_id")
  private let totalInputTokens = SQLite.Expression<Int>("total_input_tokens")
  private let totalOutputTokens = SQLite.Expression<Int>("total_output_tokens")
  private let cacheReadTokens = SQLite.Expression<Int>("cache_read_tokens")
  private let cacheCreationTokens = SQLite.Expression<Int>("cache_creation_tokens")
  private let contextUsed = SQLite.Expression<Int>("context_used")
  private let model = SQLite.Expression<String?>("model")
  private let lastUserPrompt = SQLite.Expression<String?>("last_user_prompt")
  private let lastTool = SQLite.Expression<String?>("last_tool")
  private let messageCount = SQLite.Expression<Int>("message_count")
  private let lastSyncTime = SQLite.Expression<Date>("last_sync_time")

  private init() {
    let homeDir = FileManager.default.homeDirectoryForCurrentUser
    dbPath = homeDir.appendingPathComponent(".orbitdock/orbitdock.db").path
    setupDatabase()
  }

  private func setupDatabase() {
    do {
      // Write connection - for syncs
      writeDb = try Connection(dbPath)
      try writeDb?.execute("PRAGMA journal_mode = WAL")
      try writeDb?.execute("PRAGMA busy_timeout = 5000")
      try writeDb?.execute("PRAGMA synchronous = NORMAL")
      try writeDb?.execute("PRAGMA cache_size = -64000") // 64MB cache

      // Read connection - separate connection that never blocks on writes
      readDb = try Connection(dbPath, readonly: true)
      try readDb?.execute("PRAGMA cache_size = -32000") // 32MB cache for reads

      // Create tables using write connection
      try createTables()
    } catch {
      print("❌ MessageStore: Failed to setup database: \(error)")
    }
  }

  private func createTables() throws {
    guard let db = writeDb else { return }

    // Messages table
    try db.run(messages.create(ifNotExists: true) { t in
      t.column(id, primaryKey: true)
      t.column(sessionId)
      t.column(type)
      t.column(content)
      t.column(timestamp)
      t.column(sequence, defaultValue: 0) // Preserves JSONL order
      t.column(toolName)
      t.column(toolInput)
      t.column(toolOutput)
      t.column(toolDuration) // Tool execution time in seconds
      t.column(isInProgress, defaultValue: 0)
      t.column(inputTokens)
      t.column(outputTokens)
      t.column(imageData) // Legacy single image
      t.column(imageMimeType)
      t.column(imagesJson) // JSON array of all images
      t.column(thinking) // Claude's thinking trace
    })

    // Migrations for existing tables
    addColumnIfMissing(
      db,
      table: "messages",
      column: "sequence",
      sql: "ALTER TABLE messages ADD COLUMN sequence INTEGER DEFAULT 0"
    )
    addColumnIfMissing(db, table: "messages", column: "thinking", sql: "ALTER TABLE messages ADD COLUMN thinking TEXT")
    addColumnIfMissing(
      db,
      table: "messages",
      column: "tool_duration",
      sql: "ALTER TABLE messages ADD COLUMN tool_duration REAL"
    )
    addColumnIfMissing(
      db,
      table: "messages",
      column: "images_json",
      sql: "ALTER TABLE messages ADD COLUMN images_json TEXT"
    )

    // Indexes for fast queries
    try db.run(messages.createIndex(sessionId, ifNotExists: true))
    try db.run(messages.createIndex([sessionId, timestamp], ifNotExists: true))

    // Session stats table - use a new name to avoid conflicts with existing schema
    try db.run(sessionStats.create(ifNotExists: true) { t in
      t.column(statsSessionId, primaryKey: true)
      t.column(totalInputTokens, defaultValue: 0)
      t.column(totalOutputTokens, defaultValue: 0)
      t.column(cacheReadTokens, defaultValue: 0)
      t.column(cacheCreationTokens, defaultValue: 0)
      t.column(contextUsed, defaultValue: 0)
      t.column(model)
      t.column(lastUserPrompt)
      t.column(lastTool)
      t.column(messageCount, defaultValue: 0)
      t.column(lastSyncTime)
    })

  }

  private func addColumnIfMissing(_ db: Connection, table: String, column: String, sql: String) {
    guard !hasColumn(db, table: table, column: column) else { return }
    _ = try? db.run(sql)
  }

  private func hasColumn(_ db: Connection, table: String, column: String) -> Bool {
    do {
      for row in try db.prepare("PRAGMA table_info(\(table))") {
        if let name = row[1] as? String, name == column { return true }
      }
    } catch {
      return false
    }
    return false
  }

  // MARK: - Write Operations

  private func lockForSession(_ sid: String) -> NSLock {
    syncLocksMeta.lock()
    defer { syncLocksMeta.unlock() }

    if let existing = syncLocks[sid] {
      return existing
    }
    let newLock = NSLock()
    syncLocks[sid] = newLock
    return newLock
  }

  /// Write messages and stats from a parse result (called after JSONL parse)
  /// Thread-safe: only one sync per session at a time (blocks if concurrent)
  func syncFromParseResult(_ result: TranscriptParseResult, sessionId sid: String) {
    let lock = lockForSession(sid)

    // Block until we can acquire the lock - ensures sync always completes
    // This prevents race conditions where stale data is read after skipped syncs
    lock.lock()
    defer { lock.unlock() }

    let start = CFAbsoluteTimeGetCurrent()

    guard let db = writeDb else { return }

    do {
      try db.transaction {
        // Clear existing messages for this session (full re-sync)
        try db.run(messages.filter(sessionId == sid).delete())

        // Batch insert all messages
        for (index, msg) in result.messages.enumerated() {
          let toolInputJson: String? = msg.toolInput.flatMap { input in
            guard let data = try? JSONSerialization.data(withJSONObject: input) else { return nil }
            return String(data: data, encoding: .utf8)
          }

          // Serialize all images as JSON array
          let imagesJsonString: String? = msg.images.isEmpty ? nil : {
            let imagesArray = msg.images.map { image in
              [
                "data": image.data.base64EncodedString(),
                "mimeType": image.mimeType,
              ]
            }
            guard let data = try? JSONSerialization.data(withJSONObject: imagesArray) else { return nil }
            return String(data: data, encoding: .utf8)
          }()

          try db.run(messages.insert(
            id <- msg.id,
            sessionId <- sid,
            type <- msg.type.rawValue,
            content <- msg.content,
            timestamp <- msg.timestamp,
            sequence <- index, // Preserve JSONL order
            toolName <- msg.toolName,
            toolInput <- toolInputJson,
            toolOutput <- msg.toolOutput,
            toolDuration <- msg.toolDuration,
            isInProgress <- (msg.isInProgress ? 1 : 0),
            inputTokens <- msg.inputTokens,
            outputTokens <- msg.outputTokens,
            imageData <- msg.imageData, // Legacy - keep for backwards compat
            imageMimeType <- msg.imageMimeType,
            imagesJson <- imagesJsonString,
            thinking <- msg.thinking
          ))
        }

        // Update session stats
        try db.run(sessionStats.insert(
          or: .replace,
          statsSessionId <- sid,
          totalInputTokens <- result.stats.inputTokens,
          totalOutputTokens <- result.stats.outputTokens,
          cacheReadTokens <- result.stats.cacheReadTokens,
          cacheCreationTokens <- result.stats.cacheCreationTokens,
          contextUsed <- result.stats.contextUsed,
          model <- result.stats.model,
          lastUserPrompt <- result.lastUserPrompt,
          lastTool <- result.lastTool,
          messageCount <- result.messages.count,
          lastSyncTime <- Date()
        ))
      }

      let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1_000
      if elapsed > 100 { // Only log slow syncs
        print("💾 MessageStore: synced \(result.messages.count) messages in \(String(format: "%.1f", elapsed))ms")
      }
    } catch {
      print("❌ MessageStore: sync failed: \(error)")
    }
  }

  // MARK: - Read Operations

  /// Read all messages for a session (fast indexed query, never blocks on writes)
  func readMessages(sessionId sid: String) -> [TranscriptMessage] {
    let start = CFAbsoluteTimeGetCurrent()

    guard let db = readDb else { return [] }

    do {
      let query = messages
        .filter(sessionId == sid)
        .order(sequence.asc) // Use sequence to preserve JSONL order

      var result: [TranscriptMessage] = []

      for row in try db.prepare(query) {
        let toolInputDict: [String: Any]? = row[toolInput].flatMap {
          try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }

        let msgType: TranscriptMessage.MessageType = switch row[type] {
          case "user": .user
          case "assistant": .assistant
          case "tool": .tool
          case "toolResult": .toolResult
          case "thinking": .thinking
          default: .system
        }

        // Deserialize images from JSON, fallback to legacy single image
        var images: [MessageImage] = []
        if let jsonString = row[imagesJson],
           let jsonData = jsonString.data(using: .utf8),
           let jsonArray = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: String]]
        {
          for imageDict in jsonArray {
            if let base64 = imageDict["data"],
               let mimeType = imageDict["mimeType"],
               let data = Data(base64Encoded: base64)
            {
              images.append(MessageImage(data: data, mimeType: mimeType))
            }
          }
        } else if let data = row[imageData], let mimeType = row[imageMimeType] {
          // Legacy fallback - single image
          images.append(MessageImage(data: data, mimeType: mimeType))
        }

        var msg = TranscriptMessage(
          id: row[id],
          type: msgType,
          content: row[content],
          timestamp: row[timestamp],
          toolName: row[toolName],
          toolInput: toolInputDict,
          toolOutput: row[toolOutput],
          toolDuration: row[toolDuration],
          inputTokens: row[inputTokens],
          outputTokens: row[outputTokens],
          images: images
        )
        msg.isInProgress = row[isInProgress] == 1
        msg.thinking = row[thinking]
        result.append(msg)
      }

      let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1_000
      if elapsed > 100 { // Only log slow reads
        print("📖 MessageStore: read \(result.count) messages in \(String(format: "%.1f", elapsed))ms")
      }

      return result
    } catch {
      print("❌ MessageStore: read failed: \(error)")
      return []
    }
  }

  /// Read aggregated stats for a session (never blocks on writes)
  func readStats(sessionId sid: String) -> TranscriptUsageStats? {
    guard let db = readDb else { return nil }

    do {
      let query = sessionStats.filter(statsSessionId == sid)

      if let row = try db.pluck(query) {
        var stats = TranscriptUsageStats()
        stats.inputTokens = row[totalInputTokens]
        stats.outputTokens = row[totalOutputTokens]
        stats.cacheReadTokens = row[cacheReadTokens]
        stats.cacheCreationTokens = row[cacheCreationTokens]
        stats.contextUsed = row[contextUsed]
        stats.model = row[model]
        return stats
      }
    } catch {
      print("❌ MessageStore: stats read failed: \(error)")
    }
    return nil
  }

  /// Read session info (last prompt and tool, never blocks on writes)
  func readSessionInfo(sessionId sid: String) -> (lastPrompt: String?, lastTool: String?) {
    guard let db = readDb else { return (nil, nil) }

    do {
      let query = sessionStats.filter(statsSessionId == sid)

      if let row = try db.pluck(query) {
        return (row[lastUserPrompt], row[lastTool])
      }
    } catch {
      print("❌ MessageStore: session info read failed: \(error)")
    }
    return (nil, nil)
  }

  /// Check if we have synced data for a session (never blocks on writes)
  func hasData(sessionId sid: String) -> Bool {
    guard let db = readDb else { return false }

    do {
      let query = sessionStats.filter(statsSessionId == sid)
      return try db.pluck(query) != nil
    } catch {
      return false
    }
  }

  /// Read aggregate stats across all sessions (for dashboard)
  func readAllSessionStats() -> [(sessionId: String, stats: TranscriptUsageStats)] {
    guard let db = readDb else { return [] }

    do {
      var results: [(sessionId: String, stats: TranscriptUsageStats)] = []

      for row in try db.prepare(sessionStats) {
        var stats = TranscriptUsageStats()
        stats.inputTokens = row[totalInputTokens]
        stats.outputTokens = row[totalOutputTokens]
        stats.cacheReadTokens = row[cacheReadTokens]
        stats.cacheCreationTokens = row[cacheCreationTokens]
        stats.contextUsed = row[contextUsed]
        stats.model = row[model]
        results.append((sessionId: row[statsSessionId], stats: stats))
      }

      return results
    } catch {
      print("❌ MessageStore: readAllSessionStats failed: \(error)")
      return []
    }
  }

  /// Get total estimated cost across all sessions
  func totalCostAllSessions() -> Double {
    let allStats = readAllSessionStats()
    return allStats.reduce(0) { $0 + $1.stats.estimatedCostUSD }
  }

  /// Get total tokens across all sessions
  func totalTokensAllSessions() -> Int {
    let allStats = readAllSessionStats()
    return allStats.reduce(0) { total, item in
      total + item.stats.inputTokens + item.stats.outputTokens
    }
  }

  /// Get the last sync time for a session (never blocks on writes)
  func lastSyncTime(sessionId sid: String) -> Date? {
    guard let db = readDb else { return nil }

    do {
      let query = sessionStats.filter(statsSessionId == sid)
      if let row = try db.pluck(query) {
        return row[lastSyncTime]
      }
    } catch {
      print("❌ MessageStore: lastSyncTime read failed: \(error)")
    }
    return nil
  }

  // MARK: - Utility

  /// Clear all data for a session (for re-sync)
  func clearSession(sessionId sid: String) {
    guard let db = writeDb else { return }

    do {
      try db.run(messages.filter(sessionId == sid).delete())
      try db.run(sessionStats.filter(statsSessionId == sid).delete())
    } catch {
      print("❌ MessageStore: clear failed: \(error)")
    }
  }
}
