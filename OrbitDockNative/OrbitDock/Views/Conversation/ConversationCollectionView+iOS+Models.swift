#if os(iOS)

  import Foundation

  extension ConversationCollectionViewController {
    private var subagentsByID: [String: ServerSubagentInfo] {
      guard let sessionId, let serverState else { return [:] }
      return Dictionary(uniqueKeysWithValues: serverState.session(sessionId).subagents.map { ($0.id, $0) })
    }

    func buildApprovalCardModel() -> ApprovalCardModel? {
      guard let sid = sessionId,
            let serverState,
            let session = serverState.sessions.first(where: { $0.id == sid })
      else { return nil }

      let pendingId = session.pendingApprovalId?.trimmingCharacters(in: .whitespacesAndNewlines)
      let pendingApproval: ServerApprovalRequest? = {
        guard let pendingId, !pendingId.isEmpty else { return nil }
        guard let candidate = serverState.session(sid).pendingApproval else { return nil }
        return candidate.id.trimmingCharacters(in: .whitespacesAndNewlines) == pendingId ? candidate : nil
      }()

      return ApprovalCardModelBuilder.build(
        session: session,
        pendingApproval: pendingApproval,
        approvalHistory: serverState.session(sid).approvalHistory,
        transcriptMessages: serverState.conversation(sid).messages
      )
    }

    func buildTurnHeaderModel(for turnID: String) -> ConversationUtilityRowModels.TurnHeaderModel? {
      guard let turn = turnsByID[turnID] else { return nil }
      return ConversationUtilityRowModels.turnHeader(for: turn)
    }

    func buildRollupSummaryModel(for rollupID: String) -> ConversationUtilityRowModels.RollupSummaryModel? {
      guard let row = currentRows.first(where: { $0.id == .rollupSummary(rollupID) }),
            case let .rollupSummary(_, hiddenCount, totalToolCount, isExpanded, breakdown, hiddenMessageIDs) = row.payload
      else { return nil }

      let groupMessages = hiddenMessageIDs.compactMap { messagesByID[$0] }
      return ConversationUtilityRowModels.rollupSummary(
        hiddenCount: hiddenCount,
        totalToolCount: totalToolCount,
        isExpanded: isExpanded,
        breakdown: breakdown,
        messages: groupMessages
      )
    }

    func buildLiveIndicatorModel() -> ConversationUtilityRowModels.LiveIndicatorModel {
      let meta = sourceState.metadata
      return ConversationUtilityRowModels.liveIndicator(
        workStatus: meta.workStatus,
        currentTool: meta.currentTool,
        pendingToolName: meta.pendingToolName
      )
    }

    func buildLiveProgressModel(for row: TimelineRow) -> ConversationUtilityRowModels.LiveProgressModel? {
      guard case let .liveProgress(currentTool, completedCount, elapsedTime) = row.payload else { return nil }
      return ConversationUtilityRowModels.liveProgress(
        currentTool: currentTool,
        completedCount: completedCount,
        elapsedTime: elapsedTime
      )
    }

    func buildWorkerOrchestrationModel(for row: TimelineRow) -> ConversationUtilityRowModels.WorkerOrchestrationModel? {
      guard case let .workerOrchestration(_, workerIDs) = row.payload else { return nil }
      return ConversationUtilityRowModels.workerOrchestration(
        workerIDs: workerIDs,
        subagentsByID: subagentsByID
      )
    }

    func buildCollapsedTurnModel(for turnID: String) -> ConversationUtilityRowModels.CollapsedTurnModel? {
      guard let row = currentRows.first(where: { $0.id == .collapsedTurn(turnID) }),
            case let .collapsedTurn(_, userPreview, assistantPreview, toolCount, totalDuration) = row.payload
      else { return nil }

      return ConversationUtilityRowModels.collapsedTurn(
        userPreview: userPreview,
        assistantPreview: assistantPreview,
        toolCount: toolCount,
        totalDuration: totalDuration
      )
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
        supportsRichToolingCards: sourceState.metadata.supportsRichToolingCards,
        subagentsByID: subagentsByID
      )
    }

    func buildWorkerEventModel(for row: TimelineRow) -> NativeCompactToolRowModel? {
      guard case let .workerEvent(messageID) = row.payload,
            let message = messagesByID[messageID]
      else { return nil }

      return SharedModelBuilders.workerEventModel(
        from: message,
        subagentsByID: subagentsByID
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
        supportsRichToolingCards: sourceState.metadata.supportsRichToolingCards,
        subagentsByID: subagentsByID
      )
    }
  }

#endif
