#if os(iOS)

  import Foundation

  extension ConversationCollectionViewController {
    private var subagentsByID: [String: ServerSubagentInfo] {
      guard let sessionId, let serverState else { return [:] }
      return Dictionary(uniqueKeysWithValues: serverState.session(sessionId).subagents.map { ($0.id, $0) })
    }

    func buildApprovalCardModel() -> ApprovalCardModel? {
      guard let sid = sessionId,
            let serverState
      else { return nil }
      let observable = serverState.session(sid)

      let pendingId = observable.pendingApprovalId?.trimmingCharacters(in: .whitespacesAndNewlines)
      let pendingApproval: ServerApprovalRequest? = {
        guard let pendingId, !pendingId.isEmpty else { return nil }
        guard let candidate = observable.pendingApproval else { return nil }
        return candidate.id.trimmingCharacters(in: .whitespacesAndNewlines) == pendingId ? candidate : nil
      }()

      return ApprovalCardModelBuilder.build(
        session: observable.approvalCardContext,
        pendingApproval: pendingApproval,
        approvalHistory: observable.approvalHistory,
        transcriptMessages: serverState.conversation(sid).messages
      )
    }

    func buildLiveIndicatorModel() -> ConversationUtilityRowModels.LiveIndicatorModel {
      let meta = runtime?.renderStore.metadata
      return ConversationUtilityRowModels.liveIndicator(
        workStatus: meta?.workStatus ?? .unknown,
        currentTool: meta?.currentTool,
        pendingToolName: meta?.pendingToolName
      )
    }

    func buildWorkerOrchestrationModel(for row: TimelineRow) -> ConversationUtilityRowModels.WorkerOrchestrationModel? {
      guard case let .workerOrchestration(_, workerIDs) = row.payload else { return nil }
      return ConversationUtilityRowModels.workerOrchestration(
        workerIDs: workerIDs,
        subagentsByID: subagentsByID
      )
    }

    func buildActivitySummaryModel(for row: TimelineRow) -> ConversationUtilityRowModels.ActivitySummaryModel? {
      guard case let .activitySummary(_, messageIDs, isExpanded) = row.payload else { return nil }
      let messages = messageIDs.compactMap { messagesByID[$0] }
      guard !messages.isEmpty else { return nil }
      return ConversationUtilityRowModels.activitySummary(messages: messages, isExpanded: isExpanded)
    }

    func buildRichMessageModel(for row: TimelineRow) -> NativeRichMessageRowModel? {
      guard case let .message(messageId, showHeader) = row.payload else { return nil }
      guard let message = messagesByID[messageId] else { return nil }
      return SharedModelBuilders.richMessageModel(
        from: message,
        messageID: messageId,
        isThinkingExpanded: expandedThinkingIDs.contains(messageId),
        showHeader: showHeader
      )
    }

    func buildCompactToolModel(for messageId: String) -> NativeCompactToolRowModel? {
      guard let message = messagesByID[messageId], message.isToolLike else { return nil }
      return SharedModelBuilders.compactToolModel(
        from: message,
        subagentsByID: subagentsByID,
        selectedWorkerID: selectedWorkerID
      )
    }

    func buildWorkerEventModel(for row: TimelineRow) -> NativeCompactToolRowModel? {
      guard case let .workerEvent(messageID) = row.payload,
            let message = messagesByID[messageID]
      else { return nil }

      return SharedModelBuilders.workerEventModel(
        from: message,
        subagentsByID: subagentsByID,
        selectedWorkerID: selectedWorkerID
      )
    }

    func buildExpandedToolModel(for messageId: String) -> NativeExpandedToolModel? {
      guard let message = messagesByID[messageId] else {
        logger.debug("expandedToolModel[\(messageId.prefix(8))] — message not found")
        return nil
      }
      guard message.isToolLike else {
        logger.debug("expandedToolModel[\(messageId.prefix(8))] — not a tool (type=\(message.type.rawValue))")
        return nil
      }

      logger.debug(
        "expandedToolModel[\(messageId.prefix(8))] tool=\(message.toolName ?? "?") "
          + "hasOutput=\(message.toolOutput != nil) "
          + "outputLen=\(message.toolOutput?.count ?? 0) "
          + "hasInput=\(message.toolInput != nil) "
          + "inputKeys=\(message.toolInput?.keys.sorted().joined(separator: ",") ?? "nil") "
          + "content=\(message.content.prefix(60))"
      )

      return SharedModelBuilders.expandedToolModel(
        from: message,
        messageID: messageId,
        subagentsByID: subagentsByID
      )
    }
  }

#endif
