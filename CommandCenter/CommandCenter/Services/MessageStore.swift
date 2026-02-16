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
  private let timestamp = SQLite.Expression<String>("timestamp")
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


  private static let writeTimestampFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  private static let readIsoTimestampFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  private static let readTimestampFormatters: [DateFormatter] = {
    let formats = [
      "yyyy-MM-dd'T'HH:mm:ss.SSS",
      "yyyy-MM-dd HH:mm:ss.SSS",
      "yyyy-MM-dd HH:mm:ss",
    ]

    return formats.map { format in
      let formatter = DateFormatter()
      formatter.dateFormat = format
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      return formatter
    }
  }()

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

  private func serializeTimestamp(_ date: Date) -> String {
    Self.writeTimestampFormatter.string(from: date)
  }

  private func parseTimestamp(_ raw: String) -> Date {
    if let parsed = Self.writeTimestampFormatter.date(from: raw) {
      return parsed
    }

    if let parsed = Self.readIsoTimestampFormatter.date(from: raw) {
      return parsed
    }

    for formatter in Self.readTimestampFormatters {
      if let parsed = formatter.date(from: raw) {
        return parsed
      }
    }

    return Date()
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
          timestamp: parseTimestamp(row[timestamp]),
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

  /// Check if we have message data for a session (never blocks on writes)
  func hasData(sessionId sid: String) -> Bool {
    guard let db = readDb else { return false }

    do {
      let messageCount = try db.scalar(messages.filter(sessionId == sid).count)
      return messageCount > 0
    } catch {
      return false
    }
  }

  // MARK: - Codex Direct Session Operations

  /// Append a single message for Codex direct sessions (no JSONL sync)
  func appendCodexMessage(_ msg: TranscriptMessage, sessionId sid: String) {
    guard let db = writeDb else {
      print("❌ MessageStore.append: writeDb is nil!")
      return
    }

    do {
      let toolInputJson: String? = msg.toolInput.flatMap { input in
        guard let data = try? JSONSerialization.data(withJSONObject: input) else { return nil }
        return String(data: data, encoding: .utf8)
      }

      // Get current max sequence for this session
      let maxSeq = try db.scalar(
        messages.filter(sessionId == sid).select(sequence.max)
      ) ?? -1

      try db.run(messages.insert(
        id <- msg.id,
        sessionId <- sid,
        type <- msg.type.rawValue,
        content <- msg.content,
        timestamp <- serializeTimestamp(msg.timestamp),
        sequence <- maxSeq + 1,
        toolName <- msg.toolName,
        toolInput <- toolInputJson,
        toolOutput <- msg.toolOutput,
        toolDuration <- msg.toolDuration,
        isInProgress <- (msg.isInProgress ? 1 : 0),
        inputTokens <- msg.inputTokens,
        outputTokens <- msg.outputTokens,
        imageData <- nil,
        imageMimeType <- nil,
        imagesJson <- nil,
        thinking <- msg.thinking
      ))
      print("✅ MessageStore.append: inserted id=\(msg.id), seq=\(maxSeq + 1)")
    } catch {
      print("❌ MessageStore: appendCodexMessage failed: \(error)")
    }
  }

  /// Update an existing message for Codex direct sessions (e.g., tool output)
  func updateCodexMessage(_ msg: TranscriptMessage, sessionId sid: String) {
    guard let db = writeDb else { return }

    do {
      let query = messages.filter(id == msg.id && sessionId == sid)

      // Build update setters - only update non-nil fields
      var setters: [Setter] = []

      if !msg.content.isEmpty {
        setters.append(content <- msg.content)
      }

      // Serialize toolInput to JSON if present
      if let input = msg.toolInput,
         let data = try? JSONSerialization.data(withJSONObject: input),
         let inputJson = String(data: data, encoding: .utf8)
      {
        setters.append(toolInput <- inputJson)
      }

      if let output = msg.toolOutput {
        setters.append(toolOutput <- output)
      }
      if let duration = msg.toolDuration {
        setters.append(toolDuration <- duration)
      }
      setters.append(isInProgress <- (msg.isInProgress ? 1 : 0))

      if let thinkingText = msg.thinking {
        setters.append(thinking <- thinkingText)
      }

      if !setters.isEmpty {
        let rowsUpdated = try db.run(query.update(setters))
        if rowsUpdated > 0 {
          print("✅ MessageStore.update: updated id=\(msg.id)")
        } else {
          print("⚠️ MessageStore.update: no rows matched id=\(msg.id)")
        }
      }
    } catch {
      print("❌ MessageStore: updateCodexMessage failed: \(error)")
    }
  }

  /// Insert or update a message for Codex direct sessions (upsert)
  func upsertCodexMessage(_ msg: TranscriptMessage, sessionId sid: String) {
    guard let db = writeDb else {
      print("❌ MessageStore.upsert: writeDb is nil!")
      return
    }

    do {
      // Check if message exists
      let query = messages.filter(id == msg.id && sessionId == sid)
      let exists = try db.scalar(query.count) > 0

      print("🔍 MessageStore.upsert: id=\(msg.id), session=\(sid), exists=\(exists)")

      if exists {
        // Update existing
        let toolInputJson: String? = msg.toolInput.flatMap { input in
          guard let data = try? JSONSerialization.data(withJSONObject: input) else { return nil }
          return String(data: data, encoding: .utf8)
        }

        try db.run(query.update(
          type <- msg.type.rawValue,
          content <- msg.content,
          timestamp <- serializeTimestamp(msg.timestamp),
          toolName <- msg.toolName,
          toolInput <- toolInputJson,
          toolOutput <- msg.toolOutput,
          toolDuration <- msg.toolDuration,
          isInProgress <- (msg.isInProgress ? 1 : 0)
        ))
        print("✅ MessageStore.upsert: updated existing")
      } else {
        // Insert new
        print("📝 MessageStore.upsert: inserting new message")
        appendCodexMessage(msg, sessionId: sid)
      }
    } catch {
      print("❌ MessageStore: upsertCodexMessage failed: \(error)")
    }
  }

  // MARK: - Utility

  /// Clear all data for a session (for re-sync)
  func clearSession(sessionId sid: String) {
    guard let db = writeDb else { return }

    do {
      try db.run(messages.filter(sessionId == sid).delete())
    } catch {
      print("❌ MessageStore: clear failed: \(error)")
    }
  }
}
