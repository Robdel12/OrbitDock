import Foundation

enum ConversationMetadataEvent {
  case hydrate(ConversationMetadataInput)
  case selectWorker(String?)
  case clearSelection
}

struct ConversationMetadataStore: Sendable {
  private(set) var snapshot: ConversationMetadataSnapshot
  private var inspectorByWorkerID: [String: ConversationWorkerInspectorSnapshot] = [:]

  init(session: ScopedSessionID, provider: Provider = .claude, model: String? = nil) {
    snapshot = .empty(for: session, provider: provider, model: model)
  }

  mutating func apply(_ event: ConversationMetadataEvent) {
    switch event {
      case let .hydrate(input):
        let next = buildSnapshot(input: input, previous: snapshot)
        snapshot = next.snapshot
        inspectorByWorkerID = next.inspectorByWorkerID

      case let .selectWorker(workerID):
        snapshot = withSelectedWorker(workerID)

      case .clearSelection:
        snapshot = withSelectedWorker(nil)
    }
  }

  private func buildSnapshot(
    input: ConversationMetadataInput,
    previous: ConversationMetadataSnapshot
  ) -> (snapshot: ConversationMetadataSnapshot, inspectorByWorkerID: [String: ConversationWorkerInspectorSnapshot]) {
    let workers = input.workers.map(workerSnapshot).sorted(by: workerSort)
    let activeWorkerIDs = workers.filter(\.isActive).map(\.id)
    let selectedWorkerID = resolvedSelectedWorkerID(
      requested: input.selectedWorkerID,
      workers: workers,
      previousSelection: previous.selectedWorkerID
    )
    let inspectorByWorkerID = Dictionary(
      uniqueKeysWithValues: workers.map { worker in
        (
          worker.id,
          inspectorSnapshot(
            selectedWorkerID: worker.id,
            workers: workers,
            toolsByWorker: input.toolsByWorker,
            messagesByWorker: input.messagesByWorker
          )
        )
      }
    )
    let inspector = selectedWorkerID.flatMap { inspectorByWorkerID[$0] } ?? .empty

    return (
      snapshot: ConversationMetadataSnapshot(
        session: previous.session,
        isSessionActive: input.isSessionActive,
        workStatus: input.workStatus,
        currentTool: input.currentTool,
        approval: approvalSnapshot(from: input),
        workers: workers,
        activeWorkerIDs: activeWorkerIDs,
        workerInspector: inspector,
        tokenUsage: input.tokenUsage,
        tokenUsageSnapshotKind: input.tokenUsageSnapshotKind,
        provider: input.provider,
        model: input.model
      ),
      inspectorByWorkerID: inspectorByWorkerID
    )
  }

  private func withSelectedWorker(_ workerID: String?) -> ConversationMetadataSnapshot {
    let selectedWorkerID = resolvedSelectedWorkerID(
      requested: workerID,
      workers: snapshot.workers,
      previousSelection: snapshot.selectedWorkerID
    )

    return ConversationMetadataSnapshot(
      session: snapshot.session,
      isSessionActive: snapshot.isSessionActive,
      workStatus: snapshot.workStatus,
      currentTool: snapshot.currentTool,
      approval: snapshot.approval,
      workers: snapshot.workers,
      activeWorkerIDs: snapshot.activeWorkerIDs,
      workerInspector: selectedWorkerID.flatMap { inspectorByWorkerID[$0] } ?? .empty,
      tokenUsage: snapshot.tokenUsage,
      tokenUsageSnapshotKind: snapshot.tokenUsageSnapshotKind,
      provider: snapshot.provider,
      model: snapshot.model
    )
  }

  private func approvalSnapshot(from input: ConversationMetadataInput) -> ConversationApprovalSnapshot? {
    if let approval = input.approval {
      return ConversationApprovalSnapshot(
        id: approval.id,
        version: input.approvalVersion,
        type: approval.type,
        pendingQuestion: approval.questionPrompts.first?.question ?? input.pendingQuestion ?? approval.question,
        pendingToolName: approval.toolNameForDisplay ?? input.pendingToolName,
        pendingPermissionDetail: approval.preview?.compact
          ?? String.shellCommandDisplay(from: approval.command)
          ?? input.pendingPermissionDetail
          ?? approval.command,
        currentPrompt: input.currentPrompt
      )
    }

    guard let approvalID = input.pendingApprovalId?.trimmedNilIfEmpty
      ?? (input.pendingQuestion?.isEmpty == false || input.pendingToolName?.isEmpty == false || input.pendingPermissionDetail?.isEmpty == false ? "pending" : nil)
    else {
      return nil
    }

    return ConversationApprovalSnapshot(
      id: approvalID,
      version: input.approvalVersion,
      type: input.pendingQuestion?.trimmedNilIfEmpty == nil ? .exec : .question,
      pendingQuestion: input.pendingQuestion,
      pendingToolName: input.pendingToolName,
      pendingPermissionDetail: input.pendingPermissionDetail,
      currentPrompt: input.currentPrompt
    )
  }

  private func workerSnapshot(_ worker: ServerSubagentInfo) -> ConversationWorkerSnapshot {
    ConversationWorkerSnapshot(
      id: worker.id,
      title: worker.label?.trimmedNilIfEmpty ?? worker.agentType.replacingOccurrences(of: "_", with: " ").capitalized,
      subtitle: [
        worker.taskSummary?.trimmedNilIfEmpty,
        worker.resultSummary?.trimmedNilIfEmpty,
        worker.errorSummary?.trimmedNilIfEmpty,
      ].compactMap { $0 }.first,
      status: worker.status,
      agentType: worker.agentType,
      provider: worker.provider,
      model: worker.model?.trimmedNilIfEmpty,
      taskSummary: worker.taskSummary?.trimmedNilIfEmpty,
      resultSummary: worker.resultSummary?.trimmedNilIfEmpty,
      errorSummary: worker.errorSummary?.trimmedNilIfEmpty,
      startedAt: worker.startedAt,
      lastActivityAt: worker.lastActivityAt,
      endedAt: worker.endedAt,
      parentWorkerID: worker.parentSubagentId?.trimmedNilIfEmpty
    )
  }

  private func resolvedSelectedWorkerID(
    requested: String?,
    workers: [ConversationWorkerSnapshot],
    previousSelection: String?
  ) -> String? {
    let ids = Set(workers.map(\.id))
    if let requested, ids.contains(requested) {
      return requested
    }
    if let previousSelection, ids.contains(previousSelection) {
      return previousSelection
    }
    return workers.first?.id
  }

  private func inspectorSnapshot(
    selectedWorkerID: String?,
    workers: [ConversationWorkerSnapshot],
    toolsByWorker: [String: [ServerSubagentTool]],
    messagesByWorker: [String: [ServerMessage]]
  ) -> ConversationWorkerInspectorSnapshot {
    guard let selectedWorkerID,
          let selectedWorker = workers.first(where: { $0.id == selectedWorkerID })
    else {
      return .empty
    }

    return ConversationWorkerInspectorSnapshot(
      selectedWorkerID: selectedWorkerID,
      selectedWorker: selectedWorker,
      tools: (toolsByWorker[selectedWorkerID] ?? []).map(toolSnapshot),
      threadEntries: (messagesByWorker[selectedWorkerID] ?? []).map(threadEntrySnapshot),
      childWorkerIDs: workers
        .filter { $0.parentWorkerID == selectedWorkerID }
        .map(\.id)
    )
  }

  private func toolSnapshot(_ tool: ServerSubagentTool) -> ConversationWorkerToolSnapshot {
    ConversationWorkerToolSnapshot(
      id: tool.id,
      toolName: tool.toolName,
      summary: tool.summary,
      output: tool.output?.trimmedNilIfEmpty,
      isInProgress: tool.isInProgress
    )
  }

  private func threadEntrySnapshot(_ message: ServerMessage) -> ConversationWorkerThreadEntrySnapshot {
    ConversationWorkerThreadEntrySnapshot(
      id: message.id,
      type: message.type,
      title: threadTitle(for: message),
      body: threadBody(for: message),
      timestamp: message.timestamp,
      isInProgress: message.isInProgress
    )
  }

  private func threadTitle(for message: ServerMessage) -> String {
    switch message.type {
      case .assistant:
        return "Worker reply"
      case .thinking:
        return "Worker thinking"
      case .tool, .toolResult:
        return message.toolName?.trimmedNilIfEmpty ?? "Worker tool"
      case .user:
        return "Instruction"
      case .steer:
        return "Steer"
      case .shell:
        return "Shell"
    }
  }

  private func threadBody(for message: ServerMessage) -> String {
    [
      message.content.trimmedNilIfEmpty,
      message.toolOutput?.trimmedNilIfEmpty,
      message.toolInput?.trimmedNilIfEmpty,
    ]
    .compactMap { $0 }
    .first ?? "No details yet."
  }

  private func workerSort(lhs: ConversationWorkerSnapshot, rhs: ConversationWorkerSnapshot) -> Bool {
    if lhs.isActive != rhs.isActive {
      return lhs.isActive && !rhs.isActive
    }
    return sortTimestamp(lhs.lastActivityAt ?? lhs.startedAt) > sortTimestamp(rhs.lastActivityAt ?? rhs.startedAt)
  }

  private static let timestampFormatters: [ISO8601DateFormatter] = {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]

    return [fractional, plain]
  }()

  private func sortTimestamp(_ raw: String?) -> Date {
    guard let raw else { return .distantPast }
    for formatter in Self.timestampFormatters {
      if let parsed = formatter.date(from: raw) {
        return parsed
      }
    }
    return .distantPast
  }
}
