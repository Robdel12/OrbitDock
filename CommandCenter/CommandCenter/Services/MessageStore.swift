//
//  MessageStore.swift
//  CommandCenter
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
    private var writeDb: Connection?  // For syncs (exclusive writes)
    private var readDb: Connection?   // For UI reads (never blocks on writes)
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
    private let toolName = SQLite.Expression<String?>("tool_name")
    private let toolInput = SQLite.Expression<String?>("tool_input")  // JSON string
    private let toolOutput = SQLite.Expression<String?>("tool_output")
    private let isInProgress = SQLite.Expression<Int>("is_in_progress")
    private let inputTokens = SQLite.Expression<Int?>("input_tokens")
    private let outputTokens = SQLite.Expression<Int?>("output_tokens")
    private let imageData = SQLite.Expression<Data?>("image_data")
    private let imageMimeType = SQLite.Expression<String?>("image_mime_type")

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
        dbPath = homeDir.appendingPathComponent(".claude/dashboard.db").path
        setupDatabase()
    }

    private func setupDatabase() {
        do {
            // Write connection - for syncs
            writeDb = try Connection(dbPath)
            try writeDb?.execute("PRAGMA journal_mode = WAL")
            try writeDb?.execute("PRAGMA busy_timeout = 5000")
            try writeDb?.execute("PRAGMA synchronous = NORMAL")
            try writeDb?.execute("PRAGMA cache_size = -64000")  // 64MB cache

            // Read connection - separate connection that never blocks on writes
            readDb = try Connection(dbPath, readonly: true)
            try readDb?.execute("PRAGMA cache_size = -32000")  // 32MB cache for reads

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
            t.column(toolName)
            t.column(toolInput)
            t.column(toolOutput)
            t.column(isInProgress, defaultValue: 0)
            t.column(inputTokens)
            t.column(outputTokens)
            t.column(imageData)
            t.column(imageMimeType)
        })

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
    /// Thread-safe: only one sync per session at a time
    func syncFromParseResult(_ result: TranscriptParseResult, sessionId sid: String) {
        let lock = lockForSession(sid)

        // Non-blocking tryLock - if another sync is in progress, skip this one
        guard lock.try() else { return }
        defer { lock.unlock() }

        let start = CFAbsoluteTimeGetCurrent()

        guard let db = writeDb else { return }

        do {
            try db.transaction {
                // Clear existing messages for this session (full re-sync)
                try db.run(messages.filter(sessionId == sid).delete())

                // Batch insert all messages
                for msg in result.messages {
                    let toolInputJson: String? = msg.toolInput.flatMap { input in
                        guard let data = try? JSONSerialization.data(withJSONObject: input) else { return nil }
                        return String(data: data, encoding: .utf8)
                    }

                    try db.run(messages.insert(
                        id <- msg.id,
                        sessionId <- sid,
                        type <- msg.type.rawValue,
                        content <- msg.content,
                        timestamp <- msg.timestamp,
                        toolName <- msg.toolName,
                        toolInput <- toolInputJson,
                        toolOutput <- msg.toolOutput,
                        isInProgress <- (msg.isInProgress ? 1 : 0),
                        inputTokens <- msg.inputTokens,
                        outputTokens <- msg.outputTokens,
                        imageData <- msg.imageData,
                        imageMimeType <- msg.imageMimeType
                    ))
                }

                // Update session stats
                try db.run(sessionStats.insert(or: .replace,
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

            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            if elapsed > 100 {  // Only log slow syncs
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
                .order(timestamp.asc)

            var result: [TranscriptMessage] = []

            for row in try db.prepare(query) {
                let toolInputDict: [String: Any]? = row[toolInput].flatMap {
                    try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
                }

                let msgType: TranscriptMessage.MessageType = {
                    switch row[type] {
                    case "user": return .user
                    case "assistant": return .assistant
                    case "tool": return .tool
                    case "toolResult": return .toolResult
                    default: return .system
                    }
                }()

                // Convert DB single image to images array
                var images: [MessageImage] = []
                if let data = row[imageData], let mimeType = row[imageMimeType] {
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
                    toolDuration: nil,
                    inputTokens: row[inputTokens],
                    outputTokens: row[outputTokens],
                    images: images
                )
                msg.isInProgress = row[isInProgress] == 1
                result.append(msg)
            }

            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            if elapsed > 100 {  // Only log slow reads
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
