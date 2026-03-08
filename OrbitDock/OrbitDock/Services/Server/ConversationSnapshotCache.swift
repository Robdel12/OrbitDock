import Foundation
import OSLog
import SQLite3

struct CachedConversationMetadata: Codable {
  let schemaVersion: Int
  let sessionId: String
  let revision: UInt64?
  let totalMessageCount: Int
  let oldestLoadedSequence: UInt64?
  let newestLoadedSequence: UInt64?
  let currentDiff: String?
  let currentPlan: String?
  let currentTurnId: String?
  let turnDiffs: [ServerTurnDiff]
  let tokenUsage: ServerTokenUsage?
  let tokenUsageSnapshotKind: ServerTokenUsageSnapshotKind
  let cachedAt: Date

  enum CodingKeys: String, CodingKey {
    case schemaVersion
    case sessionId
    case revision
    case totalMessageCount
    case oldestLoadedSequence
    case newestLoadedSequence
    case currentDiff
    case currentPlan
    case currentTurnId
    case turnDiffs
    case tokenUsage
    case tokenUsageSnapshotKind
    case cachedAt
  }

  init(
    sessionId: String,
    revision: UInt64?,
    totalMessageCount: Int,
    oldestLoadedSequence: UInt64?,
    newestLoadedSequence: UInt64?,
    currentDiff: String?,
    currentPlan: String?,
    currentTurnId: String?,
    turnDiffs: [ServerTurnDiff],
    tokenUsage: ServerTokenUsage?,
    tokenUsageSnapshotKind: ServerTokenUsageSnapshotKind,
    cachedAt: Date = Date()
  ) {
    schemaVersion = 2
    self.sessionId = sessionId
    self.revision = revision
    self.totalMessageCount = totalMessageCount
    self.oldestLoadedSequence = oldestLoadedSequence
    self.newestLoadedSequence = newestLoadedSequence
    self.currentDiff = currentDiff
    self.currentPlan = currentPlan
    self.currentTurnId = currentTurnId
    self.turnDiffs = turnDiffs
    self.tokenUsage = tokenUsage
    self.tokenUsageSnapshotKind = tokenUsageSnapshotKind
    self.cachedAt = cachedAt
  }

  nonisolated init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    sessionId = try container.decode(String.self, forKey: .sessionId)
    revision = try container.decodeIfPresent(UInt64.self, forKey: .revision)
    totalMessageCount = try container.decode(Int.self, forKey: .totalMessageCount)
    oldestLoadedSequence = try container.decodeIfPresent(UInt64.self, forKey: .oldestLoadedSequence)
    newestLoadedSequence = try container.decodeIfPresent(UInt64.self, forKey: .newestLoadedSequence)
    currentDiff = try container.decodeIfPresent(String.self, forKey: .currentDiff)
    currentPlan = try container.decodeIfPresent(String.self, forKey: .currentPlan)
    currentTurnId = try container.decodeIfPresent(String.self, forKey: .currentTurnId)
    turnDiffs = try container.decode([ServerTurnDiff].self, forKey: .turnDiffs)
    tokenUsage = try container.decodeIfPresent(ServerTokenUsage.self, forKey: .tokenUsage)
    tokenUsageSnapshotKind = try container.decode(ServerTokenUsageSnapshotKind.self, forKey: .tokenUsageSnapshotKind)
    cachedAt = try container.decode(Date.self, forKey: .cachedAt)
  }

  nonisolated func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(sessionId, forKey: .sessionId)
    try container.encodeIfPresent(revision, forKey: .revision)
    try container.encode(totalMessageCount, forKey: .totalMessageCount)
    try container.encodeIfPresent(oldestLoadedSequence, forKey: .oldestLoadedSequence)
    try container.encodeIfPresent(newestLoadedSequence, forKey: .newestLoadedSequence)
    try container.encodeIfPresent(currentDiff, forKey: .currentDiff)
    try container.encodeIfPresent(currentPlan, forKey: .currentPlan)
    try container.encodeIfPresent(currentTurnId, forKey: .currentTurnId)
    try container.encode(turnDiffs, forKey: .turnDiffs)
    try container.encodeIfPresent(tokenUsage, forKey: .tokenUsage)
    try container.encode(tokenUsageSnapshotKind, forKey: .tokenUsageSnapshotKind)
    try container.encode(cachedAt, forKey: .cachedAt)
  }
}

struct CachedConversationReadModel {
  let metadata: CachedConversationMetadata
  let messages: [TranscriptMessage]
}

struct CachedTranscriptMessage: Codable {
  let id: String
  let sequence: UInt64?
  let type: String
  let content: String
  let timestamp: Date
  let toolName: String?
  let toolInput: [String: AnyCodable]?
  let rawToolInput: String?
  let toolOutput: String?
  let toolDuration: TimeInterval?
  let inputTokens: Int?
  let outputTokens: Int?
  let isError: Bool
  let isInProgress: Bool
  let images: [CachedMessageImage]
  let thinking: String?

  enum CodingKeys: String, CodingKey {
    case id
    case sequence
    case type
    case content
    case timestamp
    case toolName
    case toolInput
    case rawToolInput
    case toolOutput
    case toolDuration
    case inputTokens
    case outputTokens
    case isError
    case isInProgress
    case images
    case thinking
  }

  nonisolated init(_ message: TranscriptMessage) {
    id = message.id
    sequence = message.sequence
    type = message.type.rawValue
    content = message.content
    timestamp = message.timestamp
    toolName = message.toolName
    toolInput = message.toolInput?.mapValues { AnyCodable($0) }
    rawToolInput = message.rawToolInput
    toolOutput = message.toolOutput
    toolDuration = message.toolDuration
    inputTokens = message.inputTokens
    outputTokens = message.outputTokens
    isError = message.isError
    isInProgress = message.isInProgress
    images = message.images.map(CachedMessageImage.init)
    thinking = message.thinking
  }

  nonisolated var transcriptMessage: TranscriptMessage {
    TranscriptMessage(
      id: id,
      sequence: sequence,
      type: TranscriptMessage.MessageType(rawValue: type) ?? .assistant,
      content: content,
      timestamp: timestamp,
      toolName: toolName,
      toolInput: toolInput?.mapValues(\.value),
      rawToolInput: rawToolInput,
      toolOutput: toolOutput,
      toolDuration: toolDuration,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      isError: isError,
      isInProgress: isInProgress,
      images: images.map(\.messageImage),
      thinking: thinking
    )
  }

  nonisolated init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    sequence = try container.decodeIfPresent(UInt64.self, forKey: .sequence)
    type = try container.decode(String.self, forKey: .type)
    content = try container.decode(String.self, forKey: .content)
    timestamp = try container.decode(Date.self, forKey: .timestamp)
    toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
    toolInput = try container.decodeIfPresent([String: AnyCodable].self, forKey: .toolInput)
    rawToolInput = try container.decodeIfPresent(String.self, forKey: .rawToolInput)
    toolOutput = try container.decodeIfPresent(String.self, forKey: .toolOutput)
    toolDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .toolDuration)
    inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens)
    outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens)
    isError = try container.decode(Bool.self, forKey: .isError)
    isInProgress = try container.decode(Bool.self, forKey: .isInProgress)
    images = try container.decodeIfPresent([CachedMessageImage].self, forKey: .images) ?? []
    thinking = try container.decodeIfPresent(String.self, forKey: .thinking)
  }

  nonisolated func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encodeIfPresent(sequence, forKey: .sequence)
    try container.encode(type, forKey: .type)
    try container.encode(content, forKey: .content)
    try container.encode(timestamp, forKey: .timestamp)
    try container.encodeIfPresent(toolName, forKey: .toolName)
    try container.encodeIfPresent(toolInput, forKey: .toolInput)
    try container.encodeIfPresent(rawToolInput, forKey: .rawToolInput)
    try container.encodeIfPresent(toolOutput, forKey: .toolOutput)
    try container.encodeIfPresent(toolDuration, forKey: .toolDuration)
    try container.encodeIfPresent(inputTokens, forKey: .inputTokens)
    try container.encodeIfPresent(outputTokens, forKey: .outputTokens)
    try container.encode(isError, forKey: .isError)
    try container.encode(isInProgress, forKey: .isInProgress)
    try container.encode(images, forKey: .images)
    try container.encodeIfPresent(thinking, forKey: .thinking)
  }
}

struct CachedMessageImage: Codable {
  enum SourceKind: String, Codable {
    case filePath
    case dataURI
  }

  let id: String
  let sourceKind: SourceKind
  let sourceValue: String
  let mimeType: String
  let byteCount: Int

  enum CodingKeys: String, CodingKey {
    case id
    case sourceKind
    case sourceValue
    case mimeType
    case byteCount
  }

  nonisolated init(_ image: MessageImage) {
    id = image.id
    switch image.source {
      case .filePath(let path):
        sourceKind = .filePath
        sourceValue = path
      case .dataURI(let value):
        sourceKind = .dataURI
        sourceValue = value
    }
    mimeType = image.mimeType
    byteCount = image.byteCount
  }

  nonisolated var messageImage: MessageImage {
    let source: MessageImage.Source = switch sourceKind {
      case .filePath:
        .filePath(sourceValue)
      case .dataURI:
        .dataURI(sourceValue)
    }
    return MessageImage(id: id, source: source, mimeType: mimeType, byteCount: byteCount)
  }

  nonisolated init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    sourceKind = try container.decode(SourceKind.self, forKey: .sourceKind)
    sourceValue = try container.decode(String.self, forKey: .sourceValue)
    mimeType = try container.decode(String.self, forKey: .mimeType)
    byteCount = try container.decode(Int.self, forKey: .byteCount)
  }

  nonisolated func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(sourceKind, forKey: .sourceKind)
    try container.encode(sourceValue, forKey: .sourceValue)
    try container.encode(mimeType, forKey: .mimeType)
    try container.encode(byteCount, forKey: .byteCount)
  }
}

private struct CachedConversationRow {
  let sequence: Int64
  let messageId: String
  let timestamp: TimeInterval
  let payload: Data
}

actor ConversationReadModelStore {
  nonisolated private static let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "OrbitDock",
    category: "conversation-read-model"
  )

  nonisolated private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  private let databaseURL: URL
  private let maxEntries: Int
  private let maxAge: TimeInterval
  private var database: OpaquePointer?

  init(
    databaseURL: URL = PlatformPaths.orbitDockCacheDirectory.appendingPathComponent(
      "conversation-cache.sqlite",
      isDirectory: false
    ),
    maxEntries: Int = 200,
    maxAge: TimeInterval = 30 * 24 * 60 * 60
  ) {
    self.databaseURL = databaseURL
    self.maxEntries = maxEntries
    self.maxAge = maxAge
  }

  func loadConversation(endpointId: UUID, sessionId: String, limit: Int) async -> CachedConversationReadModel? {
    guard let database = openDatabase() else { return nil }
    guard let metadataData = loadMetadataData(endpointId: endpointId, sessionId: sessionId, database: database) else {
      return nil
    }
    guard let metadata = decodeMetadataData(metadataData) else { return nil }

    let rows = loadRows(
      endpointId: endpointId,
      sessionId: sessionId,
      beforeSequence: nil,
      limit: limit,
      database: database
    )
    touch(endpointId: endpointId, sessionId: sessionId, database: database)
    return CachedConversationReadModel(
      metadata: metadata,
      messages: decodeRows(rows)
    )
  }

  func loadMessagesBefore(
    endpointId: UUID,
    sessionId: String,
    beforeSequence: UInt64,
    limit: Int
  ) async -> [TranscriptMessage] {
    guard let database = openDatabase() else { return [] }
    let rows = loadRows(
      endpointId: endpointId,
      sessionId: sessionId,
      beforeSequence: beforeSequence,
      limit: limit,
      database: database
    )
    touch(endpointId: endpointId, sessionId: sessionId, database: database)
    return decodeRows(rows)
  }

  func saveMetadata(
    endpointId: UUID,
    sessionId: String,
    metadata: CachedConversationMetadata,
    lastViewedAt: Date = Date()
  ) async {
    guard let database = openDatabase() else { return }
    guard let metadataData = encodeMetadataData(metadata) else {
      Self.logger.warning("Failed to encode conversation metadata for \(sessionId, privacy: .public)")
      return
    }

    let didCommit = withTransaction(database) {
      upsertMetadata(
        endpointId: endpointId,
        sessionId: sessionId,
        metadata: metadata,
        metadataData: metadataData,
        lastViewedAt: lastViewedAt,
        database: database
      )
    }
    guard didCommit else { return }
    prune(database: database)
  }

  func upsertMessages(
    endpointId: UUID,
    sessionId: String,
    metadata: CachedConversationMetadata,
    messages: [TranscriptMessage],
    lastViewedAt: Date = Date()
  ) async {
    guard let database = openDatabase() else { return }
    let rows = encodeRows(messages)
    guard let metadataData = encodeMetadataData(metadata) else {
      Self.logger.warning("Failed to encode conversation metadata for \(sessionId, privacy: .public)")
      return
    }

    let didCommit = withTransaction(database) {
      guard upsertMetadata(
        endpointId: endpointId,
        sessionId: sessionId,
        metadata: metadata,
        metadataData: metadataData,
        lastViewedAt: lastViewedAt,
        database: database
      ) else {
        return false
      }
      return upsertRows(rows, endpointId: endpointId, sessionId: sessionId, database: database)
    }
    guard didCommit else { return }
    prune(database: database)
  }

  func save(
    endpointId: UUID,
    sessionId: String,
    metadata: CachedConversationMetadata,
    messages: [TranscriptMessage],
    lastViewedAt: Date = Date()
  ) async {
    guard let database = openDatabase() else { return }
    let rows = encodeRows(messages)
    guard let metadataData = encodeMetadataData(metadata) else {
      Self.logger.warning("Failed to encode conversation metadata for \(sessionId, privacy: .public)")
      return
    }

    let didCommit = withTransaction(database) {
      guard upsertMetadata(
        endpointId: endpointId,
        sessionId: sessionId,
        metadata: metadata,
        metadataData: metadataData,
        lastViewedAt: lastViewedAt,
        database: database
      ) else {
        return false
      }

      if rows.isEmpty {
        if metadata.totalMessageCount == 0 {
          return deleteAllRows(endpointId: endpointId, sessionId: sessionId, database: database)
        }
        return true
      }

      guard let replaceRange = storageSequenceRange(for: rows) else {
        return upsertRows(rows, endpointId: endpointId, sessionId: sessionId, database: database)
      }

      guard deleteRows(
        endpointId: endpointId,
        sessionId: sessionId,
        sequenceRange: replaceRange,
        database: database
      ) else {
        return false
      }

      return upsertRows(rows, endpointId: endpointId, sessionId: sessionId, database: database)
    }
    guard didCommit else { return }
    prune(database: database)
  }

  func delete(endpointId: UUID, sessionId: String) {
    guard let database = openDatabase() else { return }
    execute(database, sql: "BEGIN IMMEDIATE TRANSACTION;")
    defer { execute(database, sql: "COMMIT;") }

    if let deleteMeta = prepareStatement(
      database,
      sql: """
        DELETE FROM conversation_cache_meta
        WHERE endpoint_id = ? AND session_id = ?
        """
    ) {
      bind(text: endpointId.uuidString, to: 1, in: deleteMeta)
      bind(text: sessionId, to: 2, in: deleteMeta)
      sqlite3_step(deleteMeta)
      sqlite3_finalize(deleteMeta)
    }

    if let deleteRows = prepareStatement(
      database,
      sql: """
        DELETE FROM conversation_cache_messages
        WHERE endpoint_id = ? AND session_id = ?
        """
    ) {
      bind(text: endpointId.uuidString, to: 1, in: deleteRows)
      bind(text: sessionId, to: 2, in: deleteRows)
      sqlite3_step(deleteRows)
      sqlite3_finalize(deleteRows)
    }
  }

  private func encodeRows(_ messages: [TranscriptMessage]) -> [CachedConversationRow] {
    let encoder = JSONEncoder()
    var nextSequence: UInt64 = 0
    var rows: [CachedConversationRow] = []
    rows.reserveCapacity(messages.count)

    for message in messages {
      let sequence = message.sequence ?? nextSequence
      nextSequence = sequence + 1
      let cached = CachedTranscriptMessage(message)
      guard let payload = try? encoder.encode(cached) else { continue }
      rows.append(CachedConversationRow(
        sequence: Int64(sequence),
        messageId: message.id,
        timestamp: message.timestamp.timeIntervalSince1970,
        payload: payload
      ))
    }

    return rows
  }

  private func decodeRows(_ rows: [CachedConversationRow]) -> [TranscriptMessage] {
    let decoder = JSONDecoder()
    return rows.compactMap { row in
      guard let cached = try? decoder.decode(CachedTranscriptMessage.self, from: row.payload) else {
        return nil
      }
      return cached.transcriptMessage
    }
  }

  private func encodeMetadataData(_ metadata: CachedConversationMetadata) -> Data? {
    try? JSONEncoder().encode(metadata)
  }

  private func decodeMetadataData(_ data: Data) -> CachedConversationMetadata? {
    try? JSONDecoder().decode(CachedConversationMetadata.self, from: data)
  }

  private func storageSequenceRange(for rows: [CachedConversationRow]) -> ClosedRange<Int64>? {
    guard let oldest = rows.map(\.sequence).min(), let newest = rows.map(\.sequence).max() else { return nil }
    return oldest ... newest
  }

  private func loadMetadataData(endpointId: UUID, sessionId: String, database: OpaquePointer) -> Data? {
    let sql = """
      SELECT metadata_json
      FROM conversation_cache_meta
      WHERE endpoint_id = ? AND session_id = ?
      LIMIT 1
      """
    guard let statement = prepareStatement(database, sql: sql) else { return nil }
    defer { sqlite3_finalize(statement) }

    bind(text: endpointId.uuidString, to: 1, in: statement)
    bind(text: sessionId, to: 2, in: statement)

    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return data(from: statement, column: 0)
  }

  private func loadRows(
    endpointId: UUID,
    sessionId: String,
    beforeSequence: UInt64?,
    limit: Int,
    database: OpaquePointer
  ) -> [CachedConversationRow] {
    guard limit > 0 else { return [] }

    let sql: String
    if beforeSequence == nil {
      sql = """
        SELECT sequence, message_id, timestamp, message_json
        FROM conversation_cache_messages
        WHERE endpoint_id = ? AND session_id = ?
        ORDER BY sequence DESC
        LIMIT ?
        """
    } else {
      sql = """
        SELECT sequence, message_id, timestamp, message_json
        FROM conversation_cache_messages
        WHERE endpoint_id = ? AND session_id = ? AND sequence < ?
        ORDER BY sequence DESC
        LIMIT ?
        """
    }

    guard let statement = prepareStatement(database, sql: sql) else { return [] }
    defer { sqlite3_finalize(statement) }

    bind(text: endpointId.uuidString, to: 1, in: statement)
    bind(text: sessionId, to: 2, in: statement)
    if let beforeSequence {
      sqlite3_bind_int64(statement, 3, Int64(beforeSequence))
      bind(int: limit, to: 4, in: statement)
    } else {
      bind(int: limit, to: 3, in: statement)
    }

    var rows: [CachedConversationRow] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      rows.append(CachedConversationRow(
        sequence: sqlite3_column_int64(statement, 0),
        messageId: string(from: statement, column: 1),
        timestamp: sqlite3_column_double(statement, 2),
        payload: data(from: statement, column: 3)
      ))
    }
    rows.reverse()
    return rows
  }

  private func openDatabase() -> OpaquePointer? {
    if let database {
      return database
    }

    PlatformPaths.ensureDirectory(databaseURL.deletingLastPathComponent())

    var rawDatabase: OpaquePointer?
    let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(databaseURL.path, &rawDatabase, flags, nil) == SQLITE_OK else {
      if let rawDatabase {
        logSQLiteError(rawDatabase, context: "open")
        sqlite3_close(rawDatabase)
      }
      return nil
    }

    guard let database = rawDatabase else { return nil }
    self.database = database
    execute(database, sql: "PRAGMA journal_mode = WAL;")
    execute(database, sql: "PRAGMA busy_timeout = 5000;")
    execute(
      database,
      sql: """
        CREATE TABLE IF NOT EXISTS conversation_cache_meta (
          endpoint_id TEXT NOT NULL,
          session_id TEXT NOT NULL,
          revision INTEGER,
          total_message_count INTEGER NOT NULL,
          oldest_loaded_sequence INTEGER,
          newest_loaded_sequence INTEGER,
          updated_at REAL NOT NULL,
          last_viewed_at REAL NOT NULL,
          metadata_json BLOB NOT NULL,
          PRIMARY KEY (endpoint_id, session_id)
        );
        """
    )
    execute(
      database,
      sql: """
        CREATE TABLE IF NOT EXISTS conversation_cache_messages (
          endpoint_id TEXT NOT NULL,
          session_id TEXT NOT NULL,
          sequence INTEGER NOT NULL,
          message_id TEXT NOT NULL,
          timestamp REAL NOT NULL,
          message_json BLOB NOT NULL,
          PRIMARY KEY (endpoint_id, session_id, sequence),
          UNIQUE (endpoint_id, session_id, message_id)
        );
        """
    )
    execute(
      database,
      sql: """
        CREATE INDEX IF NOT EXISTS conversation_cache_meta_last_viewed_idx
        ON conversation_cache_meta(last_viewed_at DESC);
        """
    )
    execute(
      database,
      sql: """
        CREATE INDEX IF NOT EXISTS conversation_cache_messages_lookup_idx
        ON conversation_cache_messages(endpoint_id, session_id, sequence DESC);
        """
    )

    return database
  }

  private func prepareStatement(_ database: OpaquePointer, sql: String) -> OpaquePointer? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
      logSQLiteError(database, context: "prepare")
      return nil
    }
    return statement
  }

  @discardableResult
  private func execute(_ database: OpaquePointer, sql: String) -> Bool {
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
      logSQLiteError(database, context: "exec")
      return false
    }
    return true
  }

  private func withTransaction(_ database: OpaquePointer, body: () -> Bool) -> Bool {
    guard execute(database, sql: "BEGIN IMMEDIATE TRANSACTION;") else { return false }
    var didCommit = false
    defer {
      _ = execute(database, sql: didCommit ? "COMMIT;" : "ROLLBACK;")
    }
    didCommit = body()
    return didCommit
  }

  private func bind(text: String, to index: Int32, in statement: OpaquePointer) {
    sqlite3_bind_text(statement, index, text, -1, Self.sqliteTransient)
  }

  private func bind(int: Int, to index: Int32, in statement: OpaquePointer) {
    sqlite3_bind_int64(statement, index, Int64(int))
  }

  private func bind(double: Double, to index: Int32, in statement: OpaquePointer) {
    sqlite3_bind_double(statement, index, double)
  }

  private func bind(revision: UInt64?, to index: Int32, in statement: OpaquePointer) {
    bind(sequence: revision, to: index, in: statement)
  }

  private func bind(sequence: UInt64?, to index: Int32, in statement: OpaquePointer) {
    guard let sequence else {
      sqlite3_bind_null(statement, index)
      return
    }
    sqlite3_bind_int64(statement, index, Int64(sequence))
  }

  private func bind(blob data: Data, to index: Int32, in statement: OpaquePointer) {
    if data.isEmpty {
      sqlite3_bind_blob(statement, index, nil, 0, Self.sqliteTransient)
      return
    }

    let _ = data.withUnsafeBytes { rawBuffer in
      sqlite3_bind_blob(
        statement,
        index,
        rawBuffer.baseAddress,
        Int32(data.count),
        Self.sqliteTransient
      )
    }
  }

  private func data(from statement: OpaquePointer, column: Int32) -> Data {
    let count = Int(sqlite3_column_bytes(statement, column))
    guard count > 0, let bytes = sqlite3_column_blob(statement, column) else {
      return Data()
    }
    return Data(bytes: bytes, count: count)
  }

  private func string(from statement: OpaquePointer, column: Int32) -> String {
    guard let pointer = sqlite3_column_text(statement, column) else { return "" }
    return String(cString: pointer)
  }

  private func upsertMetadata(
    endpointId: UUID,
    sessionId: String,
    metadata: CachedConversationMetadata,
    metadataData: Data,
    lastViewedAt: Date,
    database: OpaquePointer
  ) -> Bool {
    let upsertMetaSQL = """
      INSERT INTO conversation_cache_meta (
        endpoint_id,
        session_id,
        revision,
        total_message_count,
        oldest_loaded_sequence,
        newest_loaded_sequence,
        updated_at,
        last_viewed_at,
        metadata_json
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(endpoint_id, session_id) DO UPDATE SET
        revision = excluded.revision,
        total_message_count = excluded.total_message_count,
        oldest_loaded_sequence = excluded.oldest_loaded_sequence,
        newest_loaded_sequence = excluded.newest_loaded_sequence,
        updated_at = excluded.updated_at,
        last_viewed_at = excluded.last_viewed_at,
        metadata_json = excluded.metadata_json
      """
    guard let upsertMeta = prepareStatement(database, sql: upsertMetaSQL) else { return false }
    defer { sqlite3_finalize(upsertMeta) }

    bind(text: endpointId.uuidString, to: 1, in: upsertMeta)
    bind(text: sessionId, to: 2, in: upsertMeta)
    bind(revision: metadata.revision, to: 3, in: upsertMeta)
    bind(int: metadata.totalMessageCount, to: 4, in: upsertMeta)
    bind(sequence: metadata.oldestLoadedSequence, to: 5, in: upsertMeta)
    bind(sequence: metadata.newestLoadedSequence, to: 6, in: upsertMeta)
    bind(double: metadata.cachedAt.timeIntervalSince1970, to: 7, in: upsertMeta)
    bind(double: lastViewedAt.timeIntervalSince1970, to: 8, in: upsertMeta)
    bind(blob: metadataData, to: 9, in: upsertMeta)

    guard sqlite3_step(upsertMeta) == SQLITE_DONE else {
      logSQLiteError(database, context: "save-meta")
      return false
    }
    return true
  }

  private func upsertRows(
    _ rows: [CachedConversationRow],
    endpointId: UUID,
    sessionId: String,
    database: OpaquePointer
  ) -> Bool {
    guard !rows.isEmpty else { return true }

    let insertMessageSQL = """
      INSERT OR REPLACE INTO conversation_cache_messages (
        endpoint_id,
        session_id,
        sequence,
        message_id,
        timestamp,
        message_json
      ) VALUES (?, ?, ?, ?, ?, ?)
      """
    guard let insertMessage = prepareStatement(database, sql: insertMessageSQL) else { return false }
    defer { sqlite3_finalize(insertMessage) }

    for row in rows {
      sqlite3_reset(insertMessage)
      sqlite3_clear_bindings(insertMessage)
      bind(text: endpointId.uuidString, to: 1, in: insertMessage)
      bind(text: sessionId, to: 2, in: insertMessage)
      sqlite3_bind_int64(insertMessage, 3, row.sequence)
      bind(text: row.messageId, to: 4, in: insertMessage)
      bind(double: row.timestamp, to: 5, in: insertMessage)
      bind(blob: row.payload, to: 6, in: insertMessage)

      guard sqlite3_step(insertMessage) == SQLITE_DONE else {
        logSQLiteError(database, context: "save-message")
        return false
      }
    }

    return true
  }

  private func deleteRows(
    endpointId: UUID,
    sessionId: String,
    sequenceRange: ClosedRange<Int64>,
    database: OpaquePointer
  ) -> Bool {
    let sql = """
      DELETE FROM conversation_cache_messages
      WHERE endpoint_id = ? AND session_id = ? AND sequence >= ? AND sequence <= ?
      """
    guard let statement = prepareStatement(database, sql: sql) else { return false }
    defer { sqlite3_finalize(statement) }

    bind(text: endpointId.uuidString, to: 1, in: statement)
    bind(text: sessionId, to: 2, in: statement)
    sqlite3_bind_int64(statement, 3, sequenceRange.lowerBound)
    sqlite3_bind_int64(statement, 4, sequenceRange.upperBound)

    guard sqlite3_step(statement) == SQLITE_DONE else {
      logSQLiteError(database, context: "delete-range")
      return false
    }
    return true
  }

  private func deleteAllRows(endpointId: UUID, sessionId: String, database: OpaquePointer) -> Bool {
    let sql = """
      DELETE FROM conversation_cache_messages
      WHERE endpoint_id = ? AND session_id = ?
      """
    guard let statement = prepareStatement(database, sql: sql) else { return false }
    defer { sqlite3_finalize(statement) }

    bind(text: endpointId.uuidString, to: 1, in: statement)
    bind(text: sessionId, to: 2, in: statement)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      logSQLiteError(database, context: "delete-all-rows")
      return false
    }
    return true
  }

  private func touch(endpointId: UUID, sessionId: String, database: OpaquePointer) {
    let sql = """
      UPDATE conversation_cache_meta
      SET last_viewed_at = ?
      WHERE endpoint_id = ? AND session_id = ?
      """
    guard let statement = prepareStatement(database, sql: sql) else { return }
    defer { sqlite3_finalize(statement) }

    bind(double: Date().timeIntervalSince1970, to: 1, in: statement)
    bind(text: endpointId.uuidString, to: 2, in: statement)
    bind(text: sessionId, to: 3, in: statement)
    sqlite3_step(statement)
  }

  private func prune(database: OpaquePointer) {
    let cutoff = Date().addingTimeInterval(-maxAge).timeIntervalSince1970
    if let deleteOld = prepareStatement(
      database,
      sql: "DELETE FROM conversation_cache_meta WHERE updated_at < ?"
    ) {
      bind(double: cutoff, to: 1, in: deleteOld)
      sqlite3_step(deleteOld)
      sqlite3_finalize(deleteOld)
    }

    if let deleteOverflow = prepareStatement(
      database,
      sql: """
        DELETE FROM conversation_cache_meta
        WHERE rowid IN (
          SELECT rowid
          FROM conversation_cache_meta
          ORDER BY last_viewed_at DESC
          LIMIT -1 OFFSET ?
        )
        """
    ) {
      bind(int: maxEntries, to: 1, in: deleteOverflow)
      sqlite3_step(deleteOverflow)
      sqlite3_finalize(deleteOverflow)
    }

    execute(
      database,
      sql: """
        DELETE FROM conversation_cache_messages
        WHERE NOT EXISTS (
          SELECT 1
          FROM conversation_cache_meta
          WHERE conversation_cache_meta.endpoint_id = conversation_cache_messages.endpoint_id
            AND conversation_cache_meta.session_id = conversation_cache_messages.session_id
        )
        """
    )
  }

  private func logSQLiteError(_ database: OpaquePointer, context: String) {
    let message: String
    if let rawMessage = sqlite3_errmsg(database) {
      message = String(cString: rawMessage)
    } else {
      message = "unknown sqlite error"
    }
    Self.logger.error("SQLite cache \(context, privacy: .public) failed: \(message, privacy: .public)")
  }
}
