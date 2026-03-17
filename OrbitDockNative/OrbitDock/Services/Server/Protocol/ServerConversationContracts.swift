//
//  ServerConversationContracts.swift
//  OrbitDock
//
//  Conversation and review protocol contracts.
//

import Foundation

// MARK: - Conversation Rows

enum ServerConversationRowType: Codable, Equatable {
  case user
  case assistant
  case thinking
  case tool
  case activityGroup
  case question
  case approval
  case worker
  case plan
  case hook
  case handoff
  case system
  case unknown

  init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    switch value {
      case "user": self = .user
      case "assistant": self = .assistant
      case "thinking": self = .thinking
      case "tool": self = .tool
      case "activity_group": self = .activityGroup
      case "question": self = .question
      case "approval": self = .approval
      case "worker": self = .worker
      case "plan": self = .plan
      case "hook": self = .hook
      case "handoff": self = .handoff
      case "system": self = .system
      default:
        netLog(.error, cat: .ws, "Unknown conversation row type: \(value)")
        self = .unknown
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
      case .user: try container.encode("user")
      case .assistant: try container.encode("assistant")
      case .thinking: try container.encode("thinking")
      case .tool: try container.encode("tool")
      case .activityGroup: try container.encode("activity_group")
      case .question: try container.encode("question")
      case .approval: try container.encode("approval")
      case .worker: try container.encode("worker")
      case .plan: try container.encode("plan")
      case .hook: try container.encode("hook")
      case .handoff: try container.encode("handoff")
      case .system: try container.encode("system")
      case .unknown: try container.encode("unknown")
    }
  }
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
  let images: [ServerImageInput]?

  enum CodingKeys: String, CodingKey {
    case id
    case content
    case turnId = "turn_id"
    case timestamp
    case isStreaming = "is_streaming"
    case images
  }
}

/// Wire-safe tool row — no raw invocation/result payloads, guaranteed toolDisplay.
/// Mirrors Rust `ToolRowSummary`. Client renders from `toolDisplay` directly.
struct ServerConversationToolRow: Codable {
  let id: String
  let provider: ServerProvider
  let family: ServerConversationToolFamily
  let kind: ServerConversationToolKind
  let status: ServerConversationToolStatus
  let title: String
  let subtitle: String?
  let summary: String?
  let preview: ServerToolPreviewPayload?
  let startedAt: String?
  let endedAt: String?
  let durationMs: UInt64?
  let groupingKey: String?
  let renderHints: ServerConversationRenderHints
  let toolDisplay: ServerToolDisplay

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
    case renderHints = "render_hints"
    case toolDisplay = "tool_display"
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
  let response: ServerQuestionResponseValue?
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
  let worker: ServerWorkerStateSnapshot
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
  let payload: ServerPlanModePayload
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
  let payload: ServerHookPayload
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
  let payload: ServerHandoffPayload
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
        self = try .user(ServerConversationMessageRow(from: decoder))
      case .assistant:
        self = try .assistant(ServerConversationMessageRow(from: decoder))
      case .thinking:
        self = try .thinking(ServerConversationMessageRow(from: decoder))
      case .tool:
        self = try .tool(ServerConversationToolRow(from: decoder))
      case .activityGroup:
        self = try .activityGroup(ServerConversationActivityGroupRow(from: decoder))
      case .question:
        self = try .question(ServerConversationQuestionRow(from: decoder))
      case .approval:
        self = try .approval(ServerConversationApprovalRow(from: decoder))
      case .worker:
        self = try .worker(ServerConversationWorkerRow(from: decoder))
      case .plan:
        self = try .plan(ServerConversationPlanRow(from: decoder))
      case .hook:
        self = try .hook(ServerConversationHookRow(from: decoder))
      case .handoff:
        self = try .handoff(ServerConversationHandoffRow(from: decoder))
      case .system:
        self = try .system(ServerConversationMessageRow(from: decoder))
      case .unknown:
        // Decode minimal system row for unknown types — id may be present or synthesized
        let id = (try? container.decode(String.self, forKey: .rowType)) ?? UUID().uuidString
        self = .system(ServerConversationMessageRow(
          id: "unknown-\(id)",
          content: "",
          turnId: nil,
          timestamp: nil,
          isStreaming: false,
          images: nil
        ))
    }
  }

  func encode(to encoder: Encoder) throws {
    switch self {
      case let .user(row):
        try row.encode(to: encoder)
      case let .assistant(row):
        try row.encode(to: encoder)
      case let .thinking(row):
        try row.encode(to: encoder)
      case let .tool(row):
        try row.encode(to: encoder)
      case let .activityGroup(row):
        try row.encode(to: encoder)
      case let .question(row):
        try row.encode(to: encoder)
      case let .approval(row):
        try row.encode(to: encoder)
      case let .worker(row):
        try row.encode(to: encoder)
      case let .plan(row):
        try row.encode(to: encoder)
      case let .hook(row):
        try row.encode(to: encoder)
      case let .handoff(row):
        try row.encode(to: encoder)
      case let .system(row):
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
      case let .user(message),
           let .assistant(message),
           let .thinking(message),
           let .system(message):
        message.id
      case let .tool(tool):
        tool.id
      case let .activityGroup(group):
        group.id
      case let .question(question):
        question.id
      case let .approval(approval):
        approval.id
      case let .worker(worker):
        worker.id
      case let .plan(plan):
        plan.id
      case let .hook(hook):
        hook.id
      case let .handoff(handoff):
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
    rows = try container.decodeIfPresent([ServerConversationRowEntry].self, forKey: .rows) ?? []
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

  // Expanded rendering fields
  let inputDisplay: String?
  let outputDisplay: String?
  let diffDisplay: [ServerDiffLine]?

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
    case inputDisplay = "input_display"
    case outputDisplay = "output_display"
    case diffDisplay = "diff_display"
  }

  /// Minimal placeholder for legacy conversion paths where server-computed display is unavailable.
  static func placeholder(summary: String, toolType: String) -> ServerToolDisplay {
    ServerToolDisplay(
      summary: summary, subtitle: nil, rightMeta: nil, subtitleAbsorbsMeta: false,
      glyphSymbol: "gearshape", glyphColor: "secondaryLabel", language: nil,
      diffPreview: nil, outputPreview: nil, liveOutputPreview: nil, todoItems: [],
      toolType: toolType, summaryFont: "system", displayTier: "standard",
      inputDisplay: nil, outputDisplay: nil, diffDisplay: nil
    )
  }

  init(
    summary: String, subtitle: String?, rightMeta: String?, subtitleAbsorbsMeta: Bool,
    glyphSymbol: String, glyphColor: String, language: String?,
    diffPreview: ServerToolDiffPreview?, outputPreview: String?, liveOutputPreview: String?,
    todoItems: [ServerToolTodoItem], toolType: String, summaryFont: String, displayTier: String,
    inputDisplay: String?, outputDisplay: String?, diffDisplay: [ServerDiffLine]?
  ) {
    self.summary = summary
    self.subtitle = subtitle
    self.rightMeta = rightMeta
    self.subtitleAbsorbsMeta = subtitleAbsorbsMeta
    self.glyphSymbol = glyphSymbol
    self.glyphColor = glyphColor
    self.language = language
    self.diffPreview = diffPreview
    self.outputPreview = outputPreview
    self.liveOutputPreview = liveOutputPreview
    self.todoItems = todoItems
    self.toolType = toolType
    self.summaryFont = summaryFont
    self.displayTier = displayTier
    self.inputDisplay = inputDisplay
    self.outputDisplay = outputDisplay
    self.diffDisplay = diffDisplay
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
    inputDisplay = try container.decodeIfPresent(String.self, forKey: .inputDisplay)
    outputDisplay = try container.decodeIfPresent(String.self, forKey: .outputDisplay)
    diffDisplay = try container.decodeIfPresent([ServerDiffLine].self, forKey: .diffDisplay)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(summary, forKey: .summary)
    try container.encodeIfPresent(subtitle, forKey: .subtitle)
    try container.encodeIfPresent(rightMeta, forKey: .rightMeta)
    try container.encode(subtitleAbsorbsMeta, forKey: .subtitleAbsorbsMeta)
    try container.encode(glyphSymbol, forKey: .glyphSymbol)
    try container.encode(glyphColor, forKey: .glyphColor)
    try container.encodeIfPresent(language, forKey: .language)
    try container.encodeIfPresent(diffPreview, forKey: .diffPreview)
    try container.encodeIfPresent(outputPreview, forKey: .outputPreview)
    try container.encodeIfPresent(liveOutputPreview, forKey: .liveOutputPreview)
    try container.encode(todoItems, forKey: .todoItems)
    try container.encode(toolType, forKey: .toolType)
    try container.encode(summaryFont, forKey: .summaryFont)
    try container.encode(displayTier, forKey: .displayTier)
    try container.encodeIfPresent(inputDisplay, forKey: .inputDisplay)
    try container.encodeIfPresent(outputDisplay, forKey: .outputDisplay)
    // diffDisplay is Decodable-only (ServerDiffLine); omit from encoding
    // (always nil from WebSocket, only populated via REST API response)
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
  let content: String?
  let activeForm: String?

  enum CodingKeys: String, CodingKey {
    case status
    case content
    case activeForm = "active_form"
  }
}
