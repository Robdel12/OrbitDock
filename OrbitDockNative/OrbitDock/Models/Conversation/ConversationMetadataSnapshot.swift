import Foundation

struct ConversationApprovalSnapshot: Sendable, Equatable {
  let id: String
  let version: UInt64?
  let type: ServerApprovalType
  let pendingQuestion: String?
  let pendingToolName: String?
  let pendingPermissionDetail: String?
  let currentPrompt: String?

  init(
    id: String,
    version: UInt64? = nil,
    type: ServerApprovalType,
    pendingQuestion: String? = nil,
    pendingToolName: String? = nil,
    pendingPermissionDetail: String? = nil,
    currentPrompt: String? = nil
  ) {
    self.id = id
    self.version = version
    self.type = type
    self.pendingQuestion = pendingQuestion?.trimmedNilIfEmpty
    self.pendingToolName = pendingToolName?.trimmedNilIfEmpty
    self.pendingPermissionDetail = pendingPermissionDetail?.trimmedNilIfEmpty
    self.currentPrompt = currentPrompt?.trimmedNilIfEmpty
  }
}

struct ConversationWorkerToolSnapshot: Sendable, Equatable, Identifiable {
  let id: String
  let toolName: String
  let summary: String
  let output: String?
  let isInProgress: Bool
}

struct ConversationWorkerThreadEntrySnapshot: Sendable, Equatable, Identifiable {
  let id: String
  let type: ServerMessageType
  let title: String
  let body: String
  let timestamp: String?
  let isInProgress: Bool
}

struct ConversationWorkerSnapshot: Sendable, Equatable, Identifiable {
  let id: String
  let title: String
  let subtitle: String?
  let status: ServerSubagentStatus?
  let agentType: String
  let provider: ServerProvider?
  let model: String?
  let taskSummary: String?
  let resultSummary: String?
  let errorSummary: String?
  let startedAt: String
  let lastActivityAt: String?
  let endedAt: String?
  let parentWorkerID: String?

  var isActive: Bool {
    status == .pending || status == .running
  }
}

struct ConversationWorkerInspectorSnapshot: Sendable, Equatable {
  let selectedWorkerID: String?
  let selectedWorker: ConversationWorkerSnapshot?
  let tools: [ConversationWorkerToolSnapshot]
  let threadEntries: [ConversationWorkerThreadEntrySnapshot]
  let childWorkerIDs: [String]
}

struct ConversationMetadataSnapshot: Sendable, Equatable {
  let session: ScopedSessionID
  let isSessionActive: Bool
  let workStatus: Session.WorkStatus
  let currentTool: String?
  let approval: ConversationApprovalSnapshot?
  let workers: [ConversationWorkerSnapshot]
  let activeWorkerIDs: [String]
  let workerInspector: ConversationWorkerInspectorSnapshot
  let tokenUsage: ServerTokenUsage?
  let tokenUsageSnapshotKind: ServerTokenUsageSnapshotKind?
  let provider: Provider
  let model: String?

  init(
    session: ScopedSessionID,
    isSessionActive: Bool = true,
    workStatus: Session.WorkStatus = .unknown,
    currentTool: String? = nil,
    approval: ConversationApprovalSnapshot? = nil,
    workers: [ConversationWorkerSnapshot] = [],
    activeWorkerIDs: [String] = [],
    workerInspector: ConversationWorkerInspectorSnapshot = .empty,
    tokenUsage: ServerTokenUsage? = nil,
    tokenUsageSnapshotKind: ServerTokenUsageSnapshotKind? = nil,
    provider: Provider = .claude,
    model: String? = nil
  ) {
    self.session = session
    self.isSessionActive = isSessionActive
    self.workStatus = workStatus
    self.currentTool = currentTool?.trimmedNilIfEmpty
    self.approval = approval
    self.workers = workers
    self.activeWorkerIDs = activeWorkerIDs
    self.workerInspector = workerInspector
    self.tokenUsage = tokenUsage
    self.tokenUsageSnapshotKind = tokenUsageSnapshotKind
    self.provider = provider
    self.model = model?.trimmedNilIfEmpty
  }

  var pendingToolName: String? { approval?.pendingToolName }
  var pendingPermissionDetail: String? { approval?.pendingPermissionDetail }
  var currentPrompt: String? { approval?.currentPrompt }
  var approvalID: String? { approval?.id }
  var approvalVersion: UInt64? { approval?.version }
  var pendingQuestion: String? { approval?.pendingQuestion }
  var workerIDs: [String] { workers.map(\.id) }
  var workerCount: Int { workers.count }
  var selectedWorkerID: String? { workerInspector.selectedWorkerID }

  static func empty(for session: ScopedSessionID, provider: Provider = .claude, model: String? = nil) -> Self {
    Self(session: session, provider: provider, model: model)
  }
}

struct ConversationMetadataInput {
  let isSessionActive: Bool
  let workStatus: Session.WorkStatus
  let currentTool: String?
  let pendingToolName: String?
  let pendingPermissionDetail: String?
  let currentPrompt: String?
  let approval: ServerApprovalRequest?
  let pendingApprovalId: String?
  let approvalVersion: UInt64?
  let pendingQuestion: String?
  let workers: [ServerSubagentInfo]
  let selectedWorkerID: String?
  let toolsByWorker: [String: [ServerSubagentTool]]
  let messagesByWorker: [String: [ServerMessage]]
  let tokenUsage: ServerTokenUsage?
  let tokenUsageSnapshotKind: ServerTokenUsageSnapshotKind?
  let provider: Provider
  let model: String?

  init(
    isSessionActive: Bool,
    workStatus: Session.WorkStatus,
    currentTool: String? = nil,
    pendingToolName: String? = nil,
    pendingPermissionDetail: String? = nil,
    currentPrompt: String? = nil,
    approval: ServerApprovalRequest? = nil,
    pendingApprovalId: String? = nil,
    approvalVersion: UInt64? = nil,
    pendingQuestion: String? = nil,
    workers: [ServerSubagentInfo] = [],
    selectedWorkerID: String? = nil,
    toolsByWorker: [String: [ServerSubagentTool]] = [:],
    messagesByWorker: [String: [ServerMessage]] = [:],
    tokenUsage: ServerTokenUsage? = nil,
    tokenUsageSnapshotKind: ServerTokenUsageSnapshotKind? = nil,
    provider: Provider,
    model: String? = nil
  ) {
    self.isSessionActive = isSessionActive
    self.workStatus = workStatus
    self.currentTool = currentTool
    self.pendingToolName = pendingToolName
    self.pendingPermissionDetail = pendingPermissionDetail
    self.currentPrompt = currentPrompt
    self.approval = approval
    self.pendingApprovalId = pendingApprovalId
    self.approvalVersion = approvalVersion
    self.pendingQuestion = pendingQuestion
    self.workers = workers
    self.selectedWorkerID = selectedWorkerID
    self.toolsByWorker = toolsByWorker
    self.messagesByWorker = messagesByWorker
    self.tokenUsage = tokenUsage
    self.tokenUsageSnapshotKind = tokenUsageSnapshotKind
    self.provider = provider
    self.model = model
  }
}

extension ConversationWorkerInspectorSnapshot {
  static let empty = Self(selectedWorkerID: nil, selectedWorker: nil, tools: [], threadEntries: [], childWorkerIDs: [])
}

extension String {
  var trimmedNilIfEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
