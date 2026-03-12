//
//  Session.swift
//  OrbitDock
//

import Foundation

enum SessionSemantics {
  static func displayName(
    customName: String?,
    summary: String?,
    firstPrompt: String?,
    projectName: String?,
    projectPath: String
  ) -> String {
    [
      customName,
      summary,
      firstPrompt,
      projectName,
      projectPath.components(separatedBy: "/").last,
    ]
    .compactMap { value -> String? in
      guard let value else { return nil }
      let cleaned = value.strippingXMLTags().trimmingCharacters(in: .whitespacesAndNewlines)
      return cleaned.isEmpty ? nil : cleaned
    }
    .first ?? "Unknown"
  }

  static func groupingPath(repositoryRoot: String?, projectPath: String) -> String {
    repositoryRoot ?? projectPath
  }

  static func hasLiveEndpointConnection(_ status: ConnectionStatus?) -> Bool {
    guard let status else { return true }
    return status == .connected
  }

  static func showsInMissionControl(status: Session.SessionStatus, endpointConnectionStatus: ConnectionStatus?) -> Bool {
    status == .active && hasLiveEndpointConnection(endpointConnectionStatus)
  }

  static func needsAttention(status: Session.SessionStatus, attentionReason: Session.AttentionReason) -> Bool {
    status == .active && attentionReason != .none && attentionReason != .awaitingReply
  }

  static func isReady(status: Session.SessionStatus, attentionReason: Session.AttentionReason) -> Bool {
    status == .active && attentionReason == .awaitingReply
  }
}

// MARK: - Codex Integration Mode

/// Distinguishes passive (file watching) from direct (app-server JSON-RPC) Codex sessions
enum CodexIntegrationMode: String, Hashable, Sendable {
  case passive // FSEvents watching of rollout files (current behavior)
  case direct // App-server JSON-RPC (full bidirectional control)
}

// MARK: - Claude Integration Mode

/// Distinguishes passive (hooks-based) from direct (server-managed) Claude sessions
enum ClaudeIntegrationMode: String, Hashable, Sendable {
  case passive // Hooks-based monitoring (current behavior)
  case direct // Server-managed bidirectional control
}

struct Session: Identifiable, Hashable, Sendable, SessionSummaryItem {
  let id: String
  var endpointId: UUID?
  var endpointName: String?
  var endpointConnectionStatus: ConnectionStatus?
  let projectPath: String
  let projectName: String?
  var branch: String?
  var model: String?
  var summary: String? // AI-generated conversation title
  var customName: String? // User-defined custom name (overrides summary)
  var firstPrompt: String? // First user message (conversation-specific fallback)
  var lastMessage: String? // Most recent user or assistant message (for dashboard context)
  let transcriptPath: String?
  var status: SessionStatus
  var workStatus: WorkStatus
  let startedAt: Date?
  var endedAt: Date?
  let endReason: String?
  var totalTokens: Int
  var totalCostUSD: Double
  var lastActivityAt: Date?
  var lastFilesPersistedAt: Date?
  var lastTool: String?
  var lastToolAt: Date?
  var promptCount: Int
  var toolCount: Int
  var terminalSessionId: String?
  var terminalApp: String?
  var attentionReason: AttentionReason
  var pendingToolName: String? // Which tool needs permission
  var pendingToolInput: String? // Raw tool input JSON (server passthrough for diagnostics)
  var pendingPermissionDetail: String? // Server-authored compact permission summary
  var pendingQuestion: String? // Question text from AskUserQuestion
  var provider: Provider // AI provider (claude, codex)

  // MARK: - Direct Integration

  var codexIntegrationMode: CodexIntegrationMode? // nil for non-Codex sessions
  var claudeIntegrationMode: ClaudeIntegrationMode? // nil for non-Claude direct sessions
  var codexThreadId: String? // Thread ID for direct Codex sessions
  var pendingApprovalId: String? // Request ID for approval correlation

  // MARK: - Token Usage

  var inputTokens: Int? // Input tokens used in session
  var outputTokens: Int? // Output tokens generated
  var cachedTokens: Int? // Cached input tokens (cost savings)
  var contextWindow: Int? // Model context window size
  var tokenUsageSnapshotKind: ServerTokenUsageSnapshotKind // Token snapshot semantics

  // MARK: - Turn State (transient, updated during turns)

  var gitSha: String? // Git commit SHA
  var currentCwd: String? // Agent's current working directory
  var effort: String? // Last-used reasoning effort level
  var collaborationMode: String? // Codex collaboration preset, if configured
  var multiAgent: Bool? // Codex worker spawning preference, if configured
  var personality: String? // Codex personality override, if configured
  var serviceTier: String? // Codex service tier preference, if configured
  var developerInstructions: String? // Durable session instructions, if configured

  // MARK: - Worktree Detection

  var repositoryRoot: String? // Canonical repo root (from git-common-dir)
  var isWorktree: Bool = false // True if session runs in a linked worktree
  var worktreeId: String? // Links to worktrees table record

  // MARK: - Unread Tracking

  var unreadCount: UInt64 = 0 // Server-backed unread message count

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
    endpointId: UUID? = nil,
    endpointName: String? = nil,
    endpointConnectionStatus: ConnectionStatus? = nil,
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
    lastFilesPersistedAt: Date? = nil,
    lastTool: String? = nil,
    lastToolAt: Date? = nil,
    promptCount: Int = 0,
    toolCount: Int = 0,
    terminalSessionId: String? = nil,
    terminalApp: String? = nil,
    attentionReason: AttentionReason = .none,
    pendingToolName: String? = nil,
    pendingToolInput: String? = nil,
    pendingPermissionDetail: String? = nil,
    pendingQuestion: String? = nil,
    provider: Provider = .claude,
    codexIntegrationMode: CodexIntegrationMode? = nil,
    claudeIntegrationMode: ClaudeIntegrationMode? = nil,
    codexThreadId: String? = nil,
    pendingApprovalId: String? = nil,
    inputTokens: Int? = nil,
    outputTokens: Int? = nil,
    cachedTokens: Int? = nil,
    contextWindow: Int? = nil,
    tokenUsageSnapshotKind: ServerTokenUsageSnapshotKind = .unknown
  ) {
    self.id = id
    self.endpointId = endpointId
    self.endpointName = endpointName
    self.endpointConnectionStatus = endpointConnectionStatus
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
    self.lastFilesPersistedAt = lastFilesPersistedAt
    self.lastTool = lastTool
    self.lastToolAt = lastToolAt
    self.promptCount = promptCount
    self.toolCount = toolCount
    self.terminalSessionId = terminalSessionId
    self.terminalApp = terminalApp
    self.attentionReason = attentionReason
    self.pendingToolName = pendingToolName
    self.pendingToolInput = pendingToolInput
    self.pendingPermissionDetail = pendingPermissionDetail
    self.pendingQuestion = pendingQuestion
    self.provider = provider
    self.codexIntegrationMode = codexIntegrationMode
    self.claudeIntegrationMode = claudeIntegrationMode
    self.codexThreadId = codexThreadId
    self.pendingApprovalId = pendingApprovalId
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.cachedTokens = cachedTokens
    self.contextWindow = contextWindow
    self.tokenUsageSnapshotKind = tokenUsageSnapshotKind
    collaborationMode = nil
    multiAgent = nil
    personality = nil
    serviceTier = nil
    developerInstructions = nil
  }

  var scopedID: String {
    assert(endpointId != nil, "Session.scopedID accessed without endpointId — session \(id) was not stamped")
    guard let endpointId else { return id }
    return SessionRef(endpointId: endpointId, sessionId: id).scopedID
  }

  var sessionRef: SessionRef? {
    guard let endpointId else { return nil }
    return SessionRef(endpointId: endpointId, sessionId: id)
  }

  var displayName: String {
    SessionSemantics.displayName(
      customName: customName,
      summary: summary,
      firstPrompt: firstPrompt,
      projectName: projectName,
      projectPath: projectPath
    )
  }

  /// Path used for project grouping — worktree sessions group with their parent repo.
  var groupingPath: String {
    SessionSemantics.groupingPath(repositoryRoot: repositoryRoot, projectPath: projectPath)
  }

  /// For backward compatibility
  var contextLabel: String? {
    get { customName }
    set { customName = newValue }
  }

  var isActive: Bool {
    status == .active
  }

  var hasLiveEndpointConnection: Bool {
    SessionSemantics.hasLiveEndpointConnection(endpointConnectionStatus)
  }

  /// Active dashboard surfaces should only treat sessions as live when their
  /// source endpoint is currently connected.
  var showsInMissionControl: Bool {
    SessionSemantics.showsInMissionControl(status: status, endpointConnectionStatus: endpointConnectionStatus)
  }

  var hasUnreadMessages: Bool {
    unreadCount > 0
  }

  var needsAttention: Bool {
    SessionSemantics.needsAttention(status: status, attentionReason: attentionReason)
  }

  /// Returns true if session is waiting but not blocking (just needs a reply)
  var isReady: Bool {
    SessionSemantics.isReady(status: status, attentionReason: attentionReason)
  }

  // MARK: - Direct Integration

  /// Returns true if this is a direct Codex session (not passive file watching)
  var isDirectCodex: Bool {
    provider == .codex && codexIntegrationMode == .direct
  }

  /// Passive Codex sessions come from rollout watching and should stay quiet:
  /// visible for discovery/takeover, but not treated like managed live sessions
  /// for user notifications.
  var isPassiveCodex: Bool {
    provider == .codex && codexIntegrationMode == .passive
  }

  var allowsUserNotifications: Bool {
    !isPassiveCodex
  }

  /// Returns true if this is a direct Claude session (server-managed)
  var isDirectClaude: Bool {
    provider == .claude && claudeIntegrationMode == .direct
  }

  /// Returns true if this is any direct (server-controlled) session
  var isDirect: Bool {
    isDirectCodex || isDirectClaude
  }

  /// Returns true if user can send input to this session (any direct session)
  var canSendInput: Bool {
    guard isActive else { return false }
    return isDirect
  }

  /// Returns true if this passive session can be taken over (flipped to direct)
  /// Hook-created Claude sessions have nil integration mode (not explicitly "passive"),
  /// so we treat nil as passive for Claude. Codex passive sessions are always explicitly set.
  var canTakeOver: Bool {
    guard !isDirect else { return false }
    switch provider {
      case .codex: return codexIntegrationMode == .passive
      case .claude: return claudeIntegrationMode != .direct
    }
  }

  /// Returns true if user can approve/reject a pending tool (direct Codex only)
  var canApprove: Bool {
    canSendInput && attentionReason == .awaitingPermission && pendingApprovalId != nil
  }

  /// Returns true if user can answer a pending question (direct Codex only)
  var canAnswer: Bool {
    canSendInput && attentionReason == .awaitingQuestion && pendingApprovalId != nil
  }

  /// Returns true if the approval/question overlay should be shown.
  /// Covers both direct sessions (can approve inline) and passive sessions
  /// with a pending approval (need takeover first).
  var needsApprovalOverlay: Bool {
    guard isActive, pendingApprovalId != nil else { return false }
    return attentionReason == .awaitingPermission || attentionReason == .awaitingQuestion
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

  // MARK: - Token Usage Computed Properties

  /// Effective context input tokens using provider + snapshot semantics.
  var effectiveContextInputTokens: Int {
    SessionTokenUsageSemantics.effectiveContextInputTokens(
      inputTokens: inputTokens,
      cachedTokens: cachedTokens,
      snapshotKind: tokenUsageSnapshotKind,
      provider: provider
    )
  }

  /// Effective context fill fraction (0-1).
  var contextFillFraction: Double {
    SessionTokenUsageSemantics.contextFillFraction(
      contextWindow: contextWindow,
      effectiveContextInputTokens: effectiveContextInputTokens
    )
  }

  /// Effective context fill percent (0-100).
  var contextFillPercent: Double {
    contextFillFraction * 100
  }

  /// Effective cache share based on snapshot semantics.
  var effectiveCacheHitPercent: Double {
    SessionTokenUsageSemantics.effectiveCacheHitPercent(
      inputTokens: inputTokens,
      cachedTokens: cachedTokens,
      snapshotKind: tokenUsageSnapshotKind,
      effectiveContextInputTokens: effectiveContextInputTokens
    )
  }
}

extension Session {
  mutating func applyPendingApprovalSummary(_ request: ServerApprovalRequest) {
    applyPendingApprovalProjection(SessionPendingApprovalProjection(request: request))
  }

  mutating func clearPendingApprovalSummary(resetAttention: Bool) {
    pendingApprovalId = nil
    pendingToolName = nil
    pendingToolInput = nil
    pendingPermissionDetail = nil
    pendingQuestion = nil

    guard resetAttention else { return }

    if attentionReason == .awaitingPermission || attentionReason == .awaitingQuestion {
      attentionReason = .none
    }
    if workStatus == .permission {
      workStatus = .working
    }
  }
}
