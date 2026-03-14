//
//  ServerConversationContracts.swift
//  OrbitDock
//
//  Conversation and review protocol contracts.
//

import Foundation

// MARK: - Message Types

enum ServerMessageType: String, Codable {
  case user
  case assistant
  case thinking
  case tool
  case toolResult = "tool_result"
  case steer
  case shell
}

// MARK: - Core Types

struct ServerMessage: Codable, Identifiable {
  let id: String
  let sessionId: String
  let sequence: UInt64?
  let type: ServerMessageType
  let content: String
  let toolName: String?
  let toolInput: String? // JSON string
  let toolOutput: String?
  let isError: Bool
  let isInProgress: Bool
  let timestamp: String
  let durationMs: UInt64?
  let images: [ServerImageInput]
  let toolFamily: String?
  let toolDisplay: ServerToolDisplay?

  enum CodingKeys: String, CodingKey {
    case id
    case sessionId = "session_id"
    case sequence
    case type = "message_type"
    case content
    case toolName = "tool_name"
    case toolInput = "tool_input"
    case toolOutput = "tool_output"
    case isError = "is_error"
    case isInProgress = "is_in_progress"
    case timestamp
    case durationMs = "duration_ms"
    case images
    case toolFamily = "tool_family"
    case toolDisplay = "tool_display"
  }

  init(
    id: String,
    sessionId: String,
    sequence: UInt64?,
    type: ServerMessageType,
    content: String,
    toolName: String?,
    toolInput: String?,
    toolOutput: String?,
    isError: Bool,
    isInProgress: Bool,
    timestamp: String,
    durationMs: UInt64?,
    images: [ServerImageInput],
    toolFamily: String? = nil,
    toolDisplay: ServerToolDisplay? = nil
  ) {
    self.id = id
    self.sessionId = sessionId
    self.sequence = sequence
    self.type = type
    self.content = content
    self.toolName = toolName
    self.toolInput = toolInput
    self.toolOutput = toolOutput
    self.isError = isError
    self.isInProgress = isInProgress
    self.timestamp = timestamp
    self.durationMs = durationMs
    self.images = images
    self.toolFamily = toolFamily
    self.toolDisplay = toolDisplay
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    sessionId = try container.decode(String.self, forKey: .sessionId)
    sequence = try container.decodeIfPresent(UInt64.self, forKey: .sequence)
    type = try container.decode(ServerMessageType.self, forKey: .type)
    content = try container.decode(String.self, forKey: .content)
    toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
    toolInput = try container.decodeIfPresent(String.self, forKey: .toolInput)
    toolOutput = try container.decodeIfPresent(String.self, forKey: .toolOutput)
    isError = try container.decode(Bool.self, forKey: .isError)
    isInProgress = try container.decodeIfPresent(Bool.self, forKey: .isInProgress) ?? false
    timestamp = try container.decode(String.self, forKey: .timestamp)
    durationMs = try container.decodeIfPresent(UInt64.self, forKey: .durationMs)
    images = try container.decodeIfPresent([ServerImageInput].self, forKey: .images) ?? []
    toolFamily = try container.decodeIfPresent(String.self, forKey: .toolFamily)
    toolDisplay = try container.decodeIfPresent(ServerToolDisplay.self, forKey: .toolDisplay)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(sessionId, forKey: .sessionId)
    try container.encodeIfPresent(sequence, forKey: .sequence)
    try container.encode(type, forKey: .type)
    try container.encode(content, forKey: .content)
    try container.encodeIfPresent(toolName, forKey: .toolName)
    try container.encodeIfPresent(toolInput, forKey: .toolInput)
    try container.encodeIfPresent(toolOutput, forKey: .toolOutput)
    try container.encode(isError, forKey: .isError)
    if isInProgress {
      try container.encode(isInProgress, forKey: .isInProgress)
    }
    try container.encode(timestamp, forKey: .timestamp)
    try container.encodeIfPresent(durationMs, forKey: .durationMs)
    if !images.isEmpty {
      try container.encode(images, forKey: .images)
    }
    try container.encodeIfPresent(toolFamily, forKey: .toolFamily)
    try container.encodeIfPresent(toolDisplay, forKey: .toolDisplay)
  }

  /// Parse toolInput JSON string to dictionary if needed
  var toolInputDict: [String: Any]? {
    guard let json = toolInput,
          let data = json.data(using: .utf8),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return nil
    }
    return dict
  }
}

// MARK: - Review Comments

enum ServerReviewCommentTag: String, Codable {
  case clarity
  case scope
  case risk
  case nit
}

enum ServerReviewCommentStatus: String, Codable {
  case open
  case resolved
}

struct ServerReviewComment: Codable, Identifiable {
  let id: String
  let sessionId: String
  let turnId: String?
  let filePath: String
  let lineStart: UInt32
  let lineEnd: UInt32?
  let body: String
  let tag: ServerReviewCommentTag?
  let status: ServerReviewCommentStatus
  let createdAt: String
  let updatedAt: String?

  enum CodingKeys: String, CodingKey {
    case id
    case sessionId = "session_id"
    case turnId = "turn_id"
    case filePath = "file_path"
    case lineStart = "line_start"
    case lineEnd = "line_end"
    case body
    case tag
    case status
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }
}

struct ServerConversationBootstrap: Codable {
  let session: ServerSessionState
  let totalMessageCount: UInt64
  let hasMoreBefore: Bool
  let oldestSequence: UInt64?
  let newestSequence: UInt64?

  enum CodingKeys: String, CodingKey {
    case session
    case totalMessageCount = "total_message_count"
    case hasMoreBefore = "has_more_before"
    case oldestSequence = "oldest_sequence"
    case newestSequence = "newest_sequence"
  }
}

struct ServerConversationHistoryPage: Codable {
  let sessionId: String
  let messages: [ServerMessage]
  let totalMessageCount: UInt64
  let hasMoreBefore: Bool
  let oldestSequence: UInt64?
  let newestSequence: UInt64?

  enum CodingKeys: String, CodingKey {
    case sessionId = "session_id"
    case messages
    case totalMessageCount = "total_message_count"
    case hasMoreBefore = "has_more_before"
    case oldestSequence = "oldest_sequence"
    case newestSequence = "newest_sequence"
  }
}

struct ServerMessageChanges: Codable {
  let content: String?
  let toolOutput: String?
  let isError: Bool?
  let isInProgress: Bool?
  let durationMs: UInt64?
  var toolDisplay: ServerToolDisplay? = nil

  enum CodingKeys: String, CodingKey {
    case content
    case toolOutput = "tool_output"
    case isError = "is_error"
    case isInProgress = "is_in_progress"
    case durationMs = "duration_ms"
    case toolDisplay = "tool_display"
  }
}

// MARK: - Tool Display (Server-Computed)

struct ServerToolDisplay: Codable {
  let summary: String
  let subtitle: String?
  let rightMeta: String?
  let subtitleAbsorbsMeta: Bool
  let glyphSymbol: String
  let glyphColor: String
  let language: String?
  let diffPreview: ServerToolDiffPreview?
  let outputPreview: String?
  let liveOutputPreview: String?
  let todoItems: [ServerToolTodoItem]
  let toolType: String
  let summaryFont: String
  let displayTier: String

  enum CodingKeys: String, CodingKey {
    case summary
    case subtitle
    case rightMeta = "right_meta"
    case subtitleAbsorbsMeta = "subtitle_absorbs_meta"
    case glyphSymbol = "glyph_symbol"
    case glyphColor = "glyph_color"
    case language
    case diffPreview = "diff_preview"
    case outputPreview = "output_preview"
    case liveOutputPreview = "live_output_preview"
    case todoItems = "todo_items"
    case toolType = "tool_type"
    case summaryFont = "summary_font"
    case displayTier = "display_tier"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    summary = try container.decode(String.self, forKey: .summary)
    subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
    rightMeta = try container.decodeIfPresent(String.self, forKey: .rightMeta)
    subtitleAbsorbsMeta = try container.decodeIfPresent(Bool.self, forKey: .subtitleAbsorbsMeta) ?? false
    glyphSymbol = try container.decode(String.self, forKey: .glyphSymbol)
    glyphColor = try container.decode(String.self, forKey: .glyphColor)
    language = try container.decodeIfPresent(String.self, forKey: .language)
    diffPreview = try container.decodeIfPresent(ServerToolDiffPreview.self, forKey: .diffPreview)
    outputPreview = try container.decodeIfPresent(String.self, forKey: .outputPreview)
    liveOutputPreview = try container.decodeIfPresent(String.self, forKey: .liveOutputPreview)
    todoItems = try container.decodeIfPresent([ServerToolTodoItem].self, forKey: .todoItems) ?? []
    toolType = try container.decode(String.self, forKey: .toolType)
    summaryFont = try container.decodeIfPresent(String.self, forKey: .summaryFont) ?? "system"
    displayTier = try container.decodeIfPresent(String.self, forKey: .displayTier) ?? "standard"
  }
}

struct ServerToolDiffPreview: Codable {
  let contextLine: String?
  let snippetText: String
  let snippetPrefix: String
  let isAddition: Bool
  let additions: UInt32
  let deletions: UInt32

  enum CodingKeys: String, CodingKey {
    case contextLine = "context_line"
    case snippetText = "snippet_text"
    case snippetPrefix = "snippet_prefix"
    case isAddition = "is_addition"
    case additions
    case deletions
  }
}

struct ServerToolTodoItem: Codable {
  let status: String
}
