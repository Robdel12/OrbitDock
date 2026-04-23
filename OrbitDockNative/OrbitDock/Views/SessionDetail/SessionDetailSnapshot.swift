import Foundation

struct SessionDetailSnapshot {
  let screenPresentation: SessionDetailScreenPresentation
  let usageSource: SessionDetailUsageSource
  let worktreeState: SessionDetailWorktreeState
  let reviewState: SessionDetailReviewState
  let workerState: SessionDetailWorkerState
  let currentTool: String?
  let lastActivityAt: Date?
  let footerMode: SessionDetailFooterMode
  let sessionStoreEndpointId: UUID
  let sessionId: String

  func reviewPresentation(layoutConfig: LayoutConfiguration) -> SessionDetailReviewSectionPresentation {
    SessionDetailReviewSectionPresentation(
      sessionId: sessionId,
      projectPath: screenPresentation.projectPath,
      isSessionActive: screenPresentation.isActive,
      compact: layoutConfig == .split
    )
  }

  var conversationPresentation: SessionDetailConversationSectionPresentation {
    SessionDetailConversationSectionPresentation(
      sessionId: sessionId,
      endpointId: sessionStoreEndpointId,
      isSessionActive: screenPresentation.isActive,
      displayStatus: screenPresentation.displayStatus,
      currentTool: currentTool,
      projectPath: screenPresentation.projectPath,
      canOpenFileInReview: screenPresentation.isDirect
    )
  }

  static func empty(endpointId: UUID, sessionId: String) -> SessionDetailSnapshot {
    SessionDetailSnapshot(
      screenPresentation: .empty,
      usageSource: .empty,
      worktreeState: .empty,
      reviewState: .empty,
      workerState: .empty,
      currentTool: nil,
      lastActivityAt: nil,
      footerMode: .passive,
      sessionStoreEndpointId: endpointId,
      sessionId: sessionId
    )
  }
}

struct SessionDetailScreenPresentation {
  let displayName: String
  let isDirect: Bool
  let isActive: Bool
  let displayStatus: SessionDisplayStatus
  let workStatus: Session.WorkStatus
  let provider: Provider
  let model: String?
  let effort: String?
  let endpointName: String?
  let projectPath: String
  let issueIdentifier: String?
  let missionId: String?
  let capabilities: [SessionCapability]
  let continuation: SessionContinuation
  let debugContext: SessionDetailDebugContext

  static let empty = SessionDetailScreenPresentation(
    displayName: "Session",
    isDirect: false,
    isActive: false,
    displayStatus: .ended,
    workStatus: .unknown,
    provider: .claude,
    model: nil,
    effort: nil,
    endpointName: nil,
    projectPath: "",
    issueIdentifier: nil,
    missionId: nil,
    capabilities: [],
    continuation: SessionContinuation(
      endpointId: UUID(),
      sessionId: "",
      provider: .claude,
      displayName: "Session",
      projectPath: "",
      model: nil,
      hasGitRepository: false,
      sourceServerInstanceId: nil,
      sourceIsRemoteConnection: false
    ),
    debugContext: .empty
  )
}

struct SessionDetailDebugContext {
  let sessionId: String
  let threadId: String?
  let projectPath: String
  let provider: Provider
  let codexIntegrationMode: String?
  let claudeIntegrationMode: String?

  static let empty = SessionDetailDebugContext(
    sessionId: "",
    threadId: nil,
    projectPath: "",
    provider: .claude,
    codexIntegrationMode: nil,
    claudeIntegrationMode: nil
  )
}

struct SessionDetailConversationSectionPresentation {
  let sessionId: String
  let endpointId: UUID
  let isSessionActive: Bool
  let displayStatus: SessionDisplayStatus
  let currentTool: String?
  let projectPath: String
  let canOpenFileInReview: Bool

  static let empty = SessionDetailConversationSectionPresentation(
    sessionId: "",
    endpointId: UUID(),
    isSessionActive: false,
    displayStatus: .ended,
    currentTool: nil,
    projectPath: "",
    canOpenFileInReview: false
  )
}

struct SessionDetailReviewSectionPresentation {
  let sessionId: String
  let projectPath: String
  let isSessionActive: Bool
  let compact: Bool

  static let empty = SessionDetailReviewSectionPresentation(
    sessionId: "",
    projectPath: "",
    isSessionActive: false,
    compact: false
  )
}

struct SessionDetailUsageSource {
  let model: String?
  let inputTokens: Int?
  let outputTokens: Int?
  let cachedTokens: Int?
  let contextUsed: Int
  let totalTokens: Int?

  static let empty = SessionDetailUsageSource(
    model: nil,
    inputTokens: nil,
    outputTokens: nil,
    cachedTokens: nil,
    contextUsed: 0,
    totalTokens: nil
  )
}

struct SessionDetailWorktreeState {
  let status: Session.SessionStatus
  let isWorktree: Bool
  let branch: String?
  let worktreeId: String?
  let projectPath: String

  static let empty = SessionDetailWorktreeState(
    status: .active,
    isWorktree: false,
    branch: nil,
    worktreeId: nil,
    projectPath: ""
  )
}

struct SessionDetailReviewState {
  let diff: String?
  let cumulativeDiff: String?
  let turnDiffs: [ServerTurnDiff]
  let reviewComments: [ServerReviewComment]
  let isDirect: Bool
  let turnCount: UInt64

  static let empty = SessionDetailReviewState(
    diff: nil,
    cumulativeDiff: nil,
    turnDiffs: [],
    reviewComments: [],
    isDirect: false,
    turnCount: 0
  )
}

struct SessionDetailWorkerState {
  let subagents: [ServerSubagentInfo]
  var subagentTools: [String: [ServerSubagentTool]]
  var subagentMessages: [String: [ServerConversationRowEntry]]
  var agentThreads: [ServerAgentThreadSummary]
  var agentThreadPages: [String: ServerAgentThreadConversationPage]
  let timelineRevision: Int

  static let empty = SessionDetailWorkerState(
    subagents: [],
    subagentTools: [:],
    subagentMessages: [:],
    agentThreads: [],
    agentThreadPages: [:],
    timelineRevision: 0
  )
}
