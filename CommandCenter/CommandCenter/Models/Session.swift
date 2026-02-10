//
//  Session.swift
//  OrbitDock
//

import Foundation

// MARK: - Codex Integration Mode

/// Distinguishes passive (file watching) from direct (app-server JSON-RPC) Codex sessions
enum CodexIntegrationMode: String, Hashable, Sendable {
  case passive // FSEvents watching of rollout files (current behavior)
  case direct // App-server JSON-RPC (full bidirectional control)
}

struct Session: Identifiable, Hashable, Sendable {
  let id: String
  let projectPath: String
  let projectName: String?
  let branch: String?
  let model: String?
  var summary: String? // AI-generated conversation title
  var customName: String? // User-defined custom name (overrides summary)
  var firstPrompt: String? // First user message (conversation-specific fallback)
  let transcriptPath: String?
  var status: SessionStatus
  var workStatus: WorkStatus
  let startedAt: Date?
  var endedAt: Date?
  let endReason: String?
  var totalTokens: Int
  var totalCostUSD: Double
  var lastActivityAt: Date?
  var lastTool: String?
  var lastToolAt: Date?
  var promptCount: Int
  var toolCount: Int
  var terminalSessionId: String?
  var terminalApp: String?
  var attentionReason: AttentionReason
  var pendingToolName: String? // Which tool needs permission
  var pendingToolInput: String? // JSON string of tool input (for rich permission display)
  var pendingQuestion: String? // Question text from AskUserQuestion
  var provider: Provider // AI provider (claude, codex)

  // MARK: - Codex Direct Integration

  var codexIntegrationMode: CodexIntegrationMode? // nil for non-Codex sessions
  var codexThreadId: String? // Thread ID for direct Codex sessions
  var pendingApprovalId: String? // Request ID for approval correlation

  // MARK: - Codex Token Usage

  var codexInputTokens: Int? // Input tokens used in session
  var codexOutputTokens: Int? // Output tokens generated
  var codexCachedTokens: Int? // Cached input tokens (cost savings)
  var codexContextWindow: Int? // Model context window size

  // MARK: - Codex Turn State (transient, updated during turns)

  var currentDiff: String? // Aggregated diff for current turn
  var currentPlan: [PlanStep]? // Agent's plan for current turn

  struct PlanStep: Codable, Hashable, Identifiable, Sendable {
    let step: String
    let status: String

    var id: String {
      step
    }

    var isCompleted: Bool {
      status == "completed"
    }

    var isInProgress: Bool {
      status == "inProgress"
    }
  }

  enum SessionStatus: String, Sendable {
    case active
    case idle
    case ended
  }

  enum WorkStatus: String, Sendable {
    case working // Agent is actively processing
    case waiting // Waiting for user input
    case permission // Waiting for permission approval
    case unknown // Unknown state
  }

  enum AttentionReason: String, Sendable {
    case none // Working or ended - no attention needed
    case awaitingReply // Agent finished, waiting for next prompt
    case awaitingPermission // Tool needs approval (Bash, Write, etc.)
    case awaitingQuestion // AskUserQuestion tool - agent asked a question

    var label: String {
      switch self {
        case .none: ""
        case .awaitingReply: "Ready"
        case .awaitingPermission: "Permission"
        case .awaitingQuestion: "Question"
      }
    }

    var icon: String {
      switch self {
        case .none: "circle"
        case .awaitingReply: "checkmark.circle"
        case .awaitingPermission: "lock.fill"
        case .awaitingQuestion: "questionmark.bubble"
      }
    }
  }

  /// Custom initializer with backward compatibility for legacy code using contextLabel
  nonisolated init(
    id: String,
    projectPath: String,
    projectName: String? = nil,
    branch: String? = nil,
    model: String? = nil,
    summary: String? = nil,
    customName: String? = nil,
    firstPrompt: String? = nil,
    contextLabel: String? = nil, // Legacy parameter, mapped to customName
    transcriptPath: String? = nil,
    status: SessionStatus,
    workStatus: WorkStatus,
    startedAt: Date? = nil,
    endedAt: Date? = nil,
    endReason: String? = nil,
    totalTokens: Int = 0,
    totalCostUSD: Double = 0,
    lastActivityAt: Date? = nil,
    lastTool: String? = nil,
    lastToolAt: Date? = nil,
    promptCount: Int = 0,
    toolCount: Int = 0,
    terminalSessionId: String? = nil,
    terminalApp: String? = nil,
    attentionReason: AttentionReason = .none,
    pendingToolName: String? = nil,
    pendingToolInput: String? = nil,
    pendingQuestion: String? = nil,
    provider: Provider = .claude,
    codexIntegrationMode: CodexIntegrationMode? = nil,
    codexThreadId: String? = nil,
    pendingApprovalId: String? = nil,
    codexInputTokens: Int? = nil,
    codexOutputTokens: Int? = nil,
    codexCachedTokens: Int? = nil,
    codexContextWindow: Int? = nil
  ) {
    self.id = id
    self.projectPath = projectPath
    self.projectName = projectName
    self.branch = branch
    self.model = model
    self.summary = summary
    // Don't use contextLabel as customName fallback - it's just source metadata (e.g., "codex_cli_rs")
    // Let displayName fall through to firstPrompt or projectName instead
    self.customName = customName
    self.firstPrompt = firstPrompt
    self.transcriptPath = transcriptPath
    self.status = status
    self.workStatus = workStatus
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.endReason = endReason
    self.totalTokens = totalTokens
    self.totalCostUSD = totalCostUSD
    self.lastActivityAt = lastActivityAt
    self.lastTool = lastTool
    self.lastToolAt = lastToolAt
    self.promptCount = promptCount
    self.toolCount = toolCount
    self.terminalSessionId = terminalSessionId
    self.terminalApp = terminalApp
    self.attentionReason = attentionReason
    self.pendingToolName = pendingToolName
    self.pendingToolInput = pendingToolInput
    self.pendingQuestion = pendingQuestion
    self.provider = provider
    self.codexIntegrationMode = codexIntegrationMode
    self.codexThreadId = codexThreadId
    self.pendingApprovalId = pendingApprovalId
    self.codexInputTokens = codexInputTokens
    self.codexOutputTokens = codexOutputTokens
    self.codexCachedTokens = codexCachedTokens
    self.codexContextWindow = codexContextWindow
  }

  var displayName: String {
    let raw = customName ?? summary ?? firstPrompt ?? projectName ?? projectPath.components(separatedBy: "/").last ?? "Unknown"
    return raw.strippingXMLTags()
  }

  /// For backward compatibility
  var contextLabel: String? {
    get { customName }
    set { customName = newValue }
  }

  var isActive: Bool {
    status == .active
  }

  var needsAttention: Bool {
    isActive && attentionReason != .none && attentionReason != .awaitingReply
  }

  /// Returns true if session is waiting but not blocking (just needs a reply)
  var isReady: Bool {
    isActive && attentionReason == .awaitingReply
  }

  // MARK: - Codex Direct Integration

  /// Returns true if this is a direct Codex session (not passive file watching)
  var isDirectCodex: Bool {
    provider == .codex && codexIntegrationMode == .direct
  }

  /// Returns true if user can send input to this session (direct Codex only)
  var canSendInput: Bool {
    guard isActive else { return false }
    return isDirectCodex
  }

  /// Returns true if user can approve/reject a pending tool (direct Codex only)
  var canApprove: Bool {
    canSendInput && attentionReason == .awaitingPermission && pendingApprovalId != nil
  }

  /// Returns true if user can answer a pending question (direct Codex only)
  var canAnswer: Bool {
    canSendInput && attentionReason == .awaitingQuestion && pendingApprovalId != nil
  }

  var statusIcon: String {
    if !isActive { return "moon.fill" }
    switch workStatus {
      case .working: return "bolt.fill"
      case .waiting: return "hand.raised.fill"
      case .permission: return "lock.fill"
      case .unknown: return "questionmark.circle"
    }
  }

  var statusColor: String {
    if !isActive { return "secondary" }
    switch workStatus {
      case .working: return "green"
      case .waiting: return "orange"
      case .permission: return "yellow"
      case .unknown: return "secondary"
    }
  }

  var statusLabel: String {
    if !isActive { return "Ended" }
    switch workStatus {
      case .working: return "Working"
      case .waiting: return "Waiting"
      case .permission: return "Permission"
      case .unknown: return "Active"
    }
  }

  var duration: TimeInterval? {
    guard let start = startedAt else { return nil }
    let end = endedAt ?? Date()
    return end.timeIntervalSince(start)
  }

  var formattedDuration: String {
    guard let duration else { return "--" }
    let hours = Int(duration) / 3_600
    let minutes = (Int(duration) % 3_600) / 60
    if hours > 0 {
      return "\(hours)h \(minutes)m"
    }
    return "\(minutes)m"
  }

  var formattedCost: String {
    if totalCostUSD > 0 {
      return String(format: "$%.2f", totalCostUSD)
    }
    return "--"
  }

  var lastToolDisplay: String? {
    guard let tool = lastTool, !tool.isEmpty else { return nil }
    return tool
  }

  // MARK: - Codex Token Usage Computed Properties

  /// Total tokens used (input + output)
  var codexTotalTokens: Int {
    (codexInputTokens ?? 0) + (codexOutputTokens ?? 0)
  }

  /// Percentage of context window used (0-100)
  var codexContextUsagePercent: Double {
    guard let contextWindow = codexContextWindow, contextWindow > 0 else { return 0 }
    return Double(codexTotalTokens) / Double(contextWindow) * 100
  }

  /// Whether token usage data is available
  var hasTokenUsage: Bool {
    codexInputTokens != nil || codexOutputTokens != nil
  }

  /// Formatted token count string
  var formattedTokenUsage: String {
    guard hasTokenUsage else { return "--" }
    let total = codexTotalTokens
    if total >= 1_000 {
      return String(format: "%.1fk", Double(total) / 1_000)
    }
    return "\(total)"
  }
}

// MARK: - String Extensions

extension String {
  /// Strips XML/HTML tags from a string
  /// e.g., "<bash-input>git checkout</bash-input>" → "git checkout"
  func strippingXMLTags() -> String {
    // Remove XML/HTML tags using regex
    guard let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) else {
      return self
    }
    let range = NSRange(startIndex ..< endIndex, in: self)
    let stripped = regex.stringByReplacingMatches(in: self, options: [], range: range, withTemplate: "")

    // Clean up any extra whitespace
    return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
