//
//  ServerConversationContracts.swift
//  OrbitDock
//
//  Conversation and review protocol contracts.
//

import Foundation

// MARK: - Legacy Subagent Message Types

enum ServerMessageType: String, Codable {
  case user
  case assistant
  case thinking
  case tool
  case toolResult = "tool_result"
  case steer
  case shell
}

// MARK: - Legacy Subagent Message Types

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

// MARK: - Conversation Rows

enum ServerConversationRowType: String, Codable {
  case user
  case assistant
  case thinking
  case tool
  case activityGroup = "activity_group"
  case question
  case approval
  case worker
  case plan
  case hook
  case handoff
  case system
}

enum ServerConversationToolFamily: String, Codable {
  case shell
  case fileRead = "file_read"
  case fileChange = "file_change"
  case search
  case web
  case image
  case agent
  case question
  case approval
  case permissionRequest = "permission_request"
  case plan
  case todo
  case config
  case mcp
  case hook
  case handoff
  case context
  case generic
}

enum ServerConversationToolKind: String, Codable {
  case bash
  case read
  case edit
  case write
  case notebookEdit = "notebook_edit"
  case glob
  case grep
  case toolSearch = "tool_search"
  case webSearch = "web_search"
  case webFetch = "web_fetch"
  case mcpToolCall = "mcp_tool_call"
  case readMcpResource = "read_mcp_resource"
  case listMcpResources = "list_mcp_resources"
  case subscribeMcpResource = "subscribe_mcp_resource"
  case unsubscribeMcpResource = "unsubscribe_mcp_resource"
  case subscribePolling = "subscribe_polling"
  case unsubscribePolling = "unsubscribe_polling"
  case dynamicToolCall = "dynamic_tool_call"
  case spawnAgent = "spawn_agent"
  case sendAgentInput = "send_agent_input"
  case resumeAgent = "resume_agent"
  case waitAgent = "wait_agent"
  case closeAgent = "close_agent"
  case taskOutput = "task_output"
  case taskStop = "task_stop"
  case askUserQuestion = "ask_user_question"
  case enterPlanMode = "enter_plan_mode"
  case exitPlanMode = "exit_plan_mode"
  case updatePlan = "update_plan"
  case todoWrite = "todo_write"
  case config
  case enterWorktree = "enter_worktree"
  case hookNotification = "hook_notification"
  case handoffRequested = "handoff_requested"
  case compactContext = "compact_context"
  case viewImage = "view_image"
  case imageGeneration = "image_generation"
  case generic
}

enum ServerConversationToolStatus: String, Codable {
  case pending
  case running
  case completed
  case failed
  case cancelled
  case blocked
  case needsInput = "needs_input"
}

enum ServerConversationActivityGroupKind: String, Codable {
  case toolBlock = "tool_block"
  case workerBlock = "worker_block"
  case mixedBlock = "mixed_block"
}

struct ServerConversationRenderHints: Codable, Equatable {
  let canExpand: Bool
  let defaultExpanded: Bool
  let emphasized: Bool
  let monospaceSummary: Bool
  let accentTone: String?

  enum CodingKeys: String, CodingKey {
    case canExpand = "can_expand"
    case defaultExpanded = "default_expanded"
    case emphasized
    case monospaceSummary = "monospace_summary"
    case accentTone = "accent_tone"
  }

  init(
    canExpand: Bool = false,
    defaultExpanded: Bool = false,
    emphasized: Bool = false,
    monospaceSummary: Bool = false,
    accentTone: String? = nil
  ) {
    self.canExpand = canExpand
    self.defaultExpanded = defaultExpanded
    self.emphasized = emphasized
    self.monospaceSummary = monospaceSummary
    self.accentTone = accentTone
  }
}

struct ServerConversationMessageRow: Codable {
  let id: String
  let content: String
  let turnId: String?
  let timestamp: String?
  let isStreaming: Bool
  let images: [ServerImageInput]

  enum CodingKeys: String, CodingKey {
    case id
    case content
    case turnId = "turn_id"
    case timestamp
    case isStreaming = "is_streaming"
    case images
  }
}

struct ServerConversationToolRow: Codable {
  let id: String
  let provider: ServerProvider
  let family: ServerConversationToolFamily
  let kind: ServerConversationToolKind
  let status: ServerConversationToolStatus
  let title: String
  let subtitle: String?
  let summary: String?
  let preview: AnyCodable?
  let startedAt: String?
  let endedAt: String?
  let durationMs: UInt64?
  let groupingKey: AnyCodable?
  let invocation: AnyCodable
  let result: AnyCodable?
  let renderHints: ServerConversationRenderHints

  enum CodingKeys: String, CodingKey {
    case id
    case provider
    case family
    case kind
    case status
    case title
    case subtitle
    case summary
    case preview
    case startedAt = "started_at"
    case endedAt = "ended_at"
    case durationMs = "duration_ms"
    case groupingKey = "grouping_key"
    case invocation
    case result
    case renderHints = "render_hints"
  }
}

struct ServerConversationActivityGroupRow: Codable {
  let id: String
  let groupKind: ServerConversationActivityGroupKind
  let title: String
  let subtitle: String?
  let summary: String?
  let childCount: Int
  let children: [ServerConversationToolRow]
  let turnId: String?
  let groupingKey: String?
  let status: ServerConversationToolStatus
  let family: ServerConversationToolFamily?
  let renderHints: ServerConversationRenderHints

  enum CodingKeys: String, CodingKey {
    case id
    case groupKind = "group_kind"
    case title
    case subtitle
    case summary
    case childCount = "child_count"
    case children
    case turnId = "turn_id"
    case groupingKey = "grouping_key"
    case status
    case family
    case renderHints = "render_hints"
  }
}

struct ServerConversationQuestionRow: Codable {
  let id: String
  let title: String
  let subtitle: String?
  let summary: String?
  let prompts: [ServerApprovalQuestionPrompt]
  let response: AnyCodable?
  let renderHints: ServerConversationRenderHints

  enum CodingKeys: String, CodingKey {
    case id
    case title
    case subtitle
    case summary
    case prompts
    case response
    case renderHints = "render_hints"
  }
}

struct ServerConversationApprovalRow: Codable {
  let id: String
  let title: String
  let subtitle: String?
  let summary: String?
  let request: AnyCodable
  let renderHints: ServerConversationRenderHints

  enum CodingKeys: String, CodingKey {
    case id
    case title
    case subtitle
    case summary
    case request
    case renderHints = "render_hints"
  }
}

struct ServerConversationWorkerRow: Codable {
  let id: String
  let title: String
  let subtitle: String?
  let summary: String?
  let worker: AnyCodable
  let operation: String?
  let renderHints: ServerConversationRenderHints

  enum CodingKeys: String, CodingKey {
    case id
    case title
    case subtitle
    case summary
    case worker
    case operation
    case renderHints = "render_hints"
  }
}

struct ServerConversationPlanRow: Codable {
  let id: String
  let title: String
  let subtitle: String?
  let summary: String?
  let payload: AnyCodable
  let renderHints: ServerConversationRenderHints

  enum CodingKeys: String, CodingKey {
    case id
    case title
    case subtitle
    case summary
    case payload
    case renderHints = "render_hints"
  }
}

struct ServerConversationHookRow: Codable {
  let id: String
  let title: String
  let subtitle: String?
  let summary: String?
  let payload: AnyCodable
  let renderHints: ServerConversationRenderHints

  enum CodingKeys: String, CodingKey {
    case id
    case title
    case subtitle
    case summary
    case payload
    case renderHints = "render_hints"
  }
}

struct ServerConversationHandoffRow: Codable {
  let id: String
  let title: String
  let subtitle: String?
  let summary: String?
  let payload: AnyCodable
  let renderHints: ServerConversationRenderHints

  enum CodingKeys: String, CodingKey {
    case id
    case title
    case subtitle
    case summary
    case payload
    case renderHints = "render_hints"
  }
}

enum ServerConversationRow: Codable {
  case user(ServerConversationMessageRow)
  case assistant(ServerConversationMessageRow)
  case thinking(ServerConversationMessageRow)
  case tool(ServerConversationToolRow)
  case activityGroup(ServerConversationActivityGroupRow)
  case question(ServerConversationQuestionRow)
  case approval(ServerConversationApprovalRow)
  case worker(ServerConversationWorkerRow)
  case plan(ServerConversationPlanRow)
  case hook(ServerConversationHookRow)
  case handoff(ServerConversationHandoffRow)
  case system(ServerConversationMessageRow)

  enum CodingKeys: String, CodingKey {
    case rowType = "row_type"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let rowType = try container.decode(ServerConversationRowType.self, forKey: .rowType)
    switch rowType {
      case .user:
        self = .user(try ServerConversationMessageRow(from: decoder))
      case .assistant:
        self = .assistant(try ServerConversationMessageRow(from: decoder))
      case .thinking:
        self = .thinking(try ServerConversationMessageRow(from: decoder))
      case .tool:
        self = .tool(try ServerConversationToolRow(from: decoder))
      case .activityGroup:
        self = .activityGroup(try ServerConversationActivityGroupRow(from: decoder))
      case .question:
        self = .question(try ServerConversationQuestionRow(from: decoder))
      case .approval:
        self = .approval(try ServerConversationApprovalRow(from: decoder))
      case .worker:
        self = .worker(try ServerConversationWorkerRow(from: decoder))
      case .plan:
        self = .plan(try ServerConversationPlanRow(from: decoder))
      case .hook:
        self = .hook(try ServerConversationHookRow(from: decoder))
      case .handoff:
        self = .handoff(try ServerConversationHandoffRow(from: decoder))
      case .system:
        self = .system(try ServerConversationMessageRow(from: decoder))
    }
  }

  func encode(to encoder: Encoder) throws {
    switch self {
      case .user(let row):
        try row.encode(to: encoder)
      case .assistant(let row):
        try row.encode(to: encoder)
      case .thinking(let row):
        try row.encode(to: encoder)
      case .tool(let row):
        try row.encode(to: encoder)
      case .activityGroup(let row):
        try row.encode(to: encoder)
      case .question(let row):
        try row.encode(to: encoder)
      case .approval(let row):
        try row.encode(to: encoder)
      case .worker(let row):
        try row.encode(to: encoder)
      case .plan(let row):
        try row.encode(to: encoder)
      case .hook(let row):
        try row.encode(to: encoder)
      case .handoff(let row):
        try row.encode(to: encoder)
      case .system(let row):
        try row.encode(to: encoder)
    }
  }
}

struct ServerConversationRowEntry: Codable, Identifiable {
  let sessionId: String
  let sequence: UInt64
  let turnId: String?
  let row: ServerConversationRow

  enum CodingKeys: String, CodingKey {
    case sessionId = "session_id"
    case sequence
    case turnId = "turn_id"
    case row
  }

  var id: String {
    switch row {
      case .user(let message),
           .assistant(let message),
           .thinking(let message),
           .system(let message):
        message.id
      case .tool(let tool):
        tool.id
      case .activityGroup(let group):
        group.id
      case .question(let question):
        question.id
      case .approval(let approval):
        approval.id
      case .worker(let worker):
        worker.id
      case .plan(let plan):
        plan.id
      case .hook(let hook):
        hook.id
      case .handoff(let handoff):
        handoff.id
    }
  }
}

struct ServerConversationRowsChanged: Codable {
  let sessionId: String
  let upserted: [ServerConversationRowEntry]
  let removedRowIds: [String]
  let totalRowCount: UInt64?

  enum CodingKeys: String, CodingKey {
    case sessionId = "session_id"
    case upserted
    case removedRowIds = "removed_row_ids"
    case totalRowCount = "total_row_count"
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

struct ServerConversationBootstrap: Decodable {
  let session: ServerSessionState
  let rows: [ServerConversationRowEntry]
  let totalRowCount: UInt64
  let hasMoreBefore: Bool
  let oldestSequence: UInt64?
  let newestSequence: UInt64?

  enum CodingKeys: String, CodingKey {
    case session
    case rows
    case totalRowCount = "total_row_count"
    case totalMessageCount = "total_message_count"
    case hasMoreBefore = "has_more_before"
    case oldestSequence = "oldest_sequence"
    case newestSequence = "newest_sequence"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    session = try container.decode(ServerSessionState.self, forKey: .session)
    rows = try container.decodeIfPresent([ServerConversationRowEntry].self, forKey: .rows) ?? session.rows
    let directTotalRowCount = try container.decodeIfPresent(UInt64.self, forKey: .totalRowCount)
    let legacyTotalMessageCount = try container.decodeIfPresent(UInt64.self, forKey: .totalMessageCount)
    totalRowCount = directTotalRowCount ?? legacyTotalMessageCount ?? UInt64(rows.count)
    hasMoreBefore = try container.decodeIfPresent(Bool.self, forKey: .hasMoreBefore) ?? false
    oldestSequence = try container.decodeIfPresent(UInt64.self, forKey: .oldestSequence)
    newestSequence = try container.decodeIfPresent(UInt64.self, forKey: .newestSequence)
  }
}

struct ServerConversationHistoryPage: Codable {
  let rows: [ServerConversationRowEntry]
  let totalRowCount: UInt64
  let hasMoreBefore: Bool
  let oldestSequence: UInt64?
  let newestSequence: UInt64?

  enum CodingKeys: String, CodingKey {
    case rows
    case totalRowCount = "total_row_count"
    case totalMessageCount = "total_message_count"
    case messages
    case sessionId = "session_id"
    case hasMoreBefore = "has_more_before"
    case oldestSequence = "oldest_sequence"
    case newestSequence = "newest_sequence"
  }

  init(
    rows: [ServerConversationRowEntry],
    totalRowCount: UInt64,
    hasMoreBefore: Bool,
    oldestSequence: UInt64?,
    newestSequence: UInt64?
  ) {
    self.rows = rows
    self.totalRowCount = totalRowCount
    self.hasMoreBefore = hasMoreBefore
    self.oldestSequence = oldestSequence
    self.newestSequence = newestSequence
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let directRows = try container.decodeIfPresent([ServerConversationRowEntry].self, forKey: .rows) {
      rows = directRows
    } else {
      let sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId) ?? ""
      let messages = try container.decodeIfPresent([ServerMessage].self, forKey: .messages) ?? []
      rows = messages.map { $0.toConversationRowEntry(defaultSessionId: sessionId) }
    }
    let directTotalRowCount = try container.decodeIfPresent(UInt64.self, forKey: .totalRowCount)
    let legacyTotalMessageCount = try container.decodeIfPresent(UInt64.self, forKey: .totalMessageCount)
    totalRowCount = directTotalRowCount ?? legacyTotalMessageCount ?? UInt64(rows.count)
    hasMoreBefore = try container.decodeIfPresent(Bool.self, forKey: .hasMoreBefore) ?? false
    oldestSequence = try container.decodeIfPresent(UInt64.self, forKey: .oldestSequence)
    newestSequence = try container.decodeIfPresent(UInt64.self, forKey: .newestSequence)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(rows, forKey: .rows)
    try container.encode(totalRowCount, forKey: .totalRowCount)
    try container.encode(hasMoreBefore, forKey: .hasMoreBefore)
    try container.encodeIfPresent(oldestSequence, forKey: .oldestSequence)
    try container.encodeIfPresent(newestSequence, forKey: .newestSequence)
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
