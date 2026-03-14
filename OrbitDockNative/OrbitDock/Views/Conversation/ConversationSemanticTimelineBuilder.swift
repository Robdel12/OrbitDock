import Foundation

enum ConversationSemanticTimelineBuilder {
  static func build(
    renderStore: ConversationRenderStore,
    messagesByID: [String: TranscriptMessage],
    hasMoreMessages: Bool,
    chatViewMode: ChatViewMode,
    expansionState: ConversationTimelineExpansionState = .init()
  ) -> [TimelineRow] {
    var rows: [TimelineRow] = []
    var pendingActivityMessageIDs: [String] = []

    func flushPendingActivity() {
      guard chatViewMode != .verbose, !pendingActivityMessageIDs.isEmpty else {
        pendingActivityMessageIDs.removeAll(keepingCapacity: true)
        return
      }

      let anchorID = pendingActivityMessageIDs.first ?? "activity"
      let isExpanded = expansionState.expandedActivityGroupIDs.contains(anchorID)
      var hasher = Hasher()
      hasher.combine(pendingActivityMessageIDs.count)
      hasher.combine(isExpanded)
      for messageID in pendingActivityMessageIDs {
        hasher.combine(messageID)
        hasher.combine(messagesByID[messageID]?.contentSignature ?? 0)
      }

      rows.append(
        TimelineRow(
          id: .activitySummary(anchorID),
          kind: .activitySummary,
          payload: .activitySummary(anchorID: anchorID, messageIDs: pendingActivityMessageIDs, isExpanded: isExpanded),
          layoutHash: pendingActivityMessageIDs.count,
          renderHash: hasher.finalize()
        )
      )
      if isExpanded {
        rows.append(contentsOf: activityDetailRows(for: pendingActivityMessageIDs, messagesByID: messagesByID))
      }
      pendingActivityMessageIDs.removeAll(keepingCapacity: true)
    }

    if hasMoreMessages {
      rows.append(
        TimelineRow(
          id: .loadMore,
          kind: .loadMore,
          payload: .none,
          layoutHash: 0,
          renderHash: 0
        )
      )
    }

    if renderStore.metadata.approval != nil {
      rows.append(
        TimelineRow(
          id: .approvalCard,
          kind: .approvalCard,
          payload: .approvalCard(mode: approvalMode(for: renderStore.metadata)),
          layoutHash: renderStore.metadata.approvalVersion.map(Int.init) ?? 0,
          renderHash: renderStore.metadata.approvalID?.hashValue ?? 0
        )
      )
    }

    if shouldShowWorkerStrip(renderStore.metadata) {
      rows.append(
        TimelineRow(
          id: .workerOrchestration("active-workers"),
          kind: .workerOrchestration,
          payload: .workerOrchestration(turnID: "active-workers", workerIDs: renderStore.metadata.workerIDs),
          layoutHash: renderStore.metadata.workerCount,
          renderHash: renderStore.metadata.workerIDs.hashValue
        )
      )
    }

    if shouldShowLiveIndicator(renderStore.metadata) {
      rows.append(
        TimelineRow(
          id: .liveIndicator,
          kind: .liveIndicator,
          payload: .none,
          layoutHash: renderStore.metadata.workStatus.hashValue,
          renderHash: [
            renderStore.metadata.workStatus.hashValue,
            renderStore.metadata.currentTool?.hashValue ?? 0,
            renderStore.metadata.pendingToolName?.hashValue ?? 0,
          ].hashValue
        )
      )
    }

    var previousRole: ConversationMessageRole?

    for record in renderStore.rows {
      switch record.payload {
        case let .message(snapshot):
          guard let message = messagesByID[snapshot.messageID] else { continue }
          if chatViewMode != .verbose, message.isToolLike {
            pendingActivityMessageIDs.append(message.id)
            continue
          }

          flushPendingActivity()
          if let row = messageRow(
            for: message,
            snapshot: snapshot,
            previousRole: previousRole,
            chatViewMode: chatViewMode
          ) {
            rows.append(row)
          }
          if !message.isToolLike {
            previousRole = snapshot.role
          }

        case .tool(let messageID):
          guard chatViewMode == .verbose else {
            pendingActivityMessageIDs.append(messageID)
            continue
          }
          rows.append(
            TimelineRow(
              id: .tool(messageID),
              kind: .tool,
              payload: .tool(id: messageID),
              layoutHash: messagesByID[messageID]?.contentSignature ?? Int(record.revision),
              renderHash: messagesByID[messageID]?.contentSignature ?? Int(record.revision)
            )
          )

        case let .worker(messageID, _):
          guard chatViewMode == .verbose else {
            pendingActivityMessageIDs.append(messageID)
            continue
          }
          rows.append(
            TimelineRow(
              id: .workerEvent(messageID),
              kind: .workerEvent,
              payload: .workerEvent(id: messageID),
              layoutHash: messagesByID[messageID]?.contentSignature ?? Int(record.revision),
              renderHash: messagesByID[messageID]?.contentSignature ?? Int(record.revision)
            )
          )

        case .approval, .status, .spacer:
          flushPendingActivity()
          continue
      }
    }

    flushPendingActivity()

    rows.append(
      TimelineRow(
        id: .bottomSpacer,
        kind: .bottomSpacer,
        payload: .none,
        layoutHash: 0,
        renderHash: 0
      )
    )

    return rows
  }

  private static func activityDetailRows(
    for messageIDs: [String],
    messagesByID: [String: TranscriptMessage]
  ) -> [TimelineRow] {
    messageIDs.compactMap { messageID in
      guard let message = messagesByID[messageID] else { return nil }
      if SharedModelBuilders.linkedWorkerID(for: message) != nil {
        return TimelineRow(
          id: .workerEvent(message.id),
          kind: .workerEvent,
          payload: .workerEvent(id: message.id),
          layoutHash: message.contentSignature,
          renderHash: message.contentSignature
        )
      }

      return TimelineRow(
        id: .tool(message.id),
        kind: .tool,
        payload: .tool(id: message.id),
        layoutHash: message.contentSignature,
        renderHash: message.contentSignature
      )
    }
  }

  private static func messageRow(
    for message: TranscriptMessage,
    snapshot: ConversationMessageSnapshot,
    previousRole: ConversationMessageRole?,
    chatViewMode: ChatViewMode
  ) -> TimelineRow? {
    if message.isToolLike {
      guard chatViewMode == .verbose else { return nil }
      if SharedModelBuilders.linkedWorkerID(for: message) != nil {
        return TimelineRow(
          id: .workerEvent(message.id),
          kind: .workerEvent,
          payload: .workerEvent(id: message.id),
          layoutHash: message.contentSignature,
          renderHash: message.contentSignature
        )
      }

      return TimelineRow(
        id: .tool(message.id),
        kind: .tool,
        payload: .tool(id: message.id),
        layoutHash: message.contentSignature,
        renderHash: message.contentSignature
      )
    }

    let showHeader = previousRole != snapshot.role
    return TimelineRow(
      id: .message(message.id),
      kind: .message,
      payload: .message(id: message.id, showHeader: showHeader),
      layoutHash: message.contentSignature,
      renderHash: message.contentSignature
    )
  }

  private static func shouldShowLiveIndicator(_ metadata: ConversationMetadataSnapshot) -> Bool {
    metadata.isSessionActive && (
      metadata.workStatus == .working
        || metadata.workStatus == .permission
        || metadata.workStatus == .waiting
        || metadata.currentTool != nil
        || metadata.pendingToolName != nil
    )
  }

  private static func shouldShowWorkerStrip(_ metadata: ConversationMetadataSnapshot) -> Bool {
    !metadata.workers.isEmpty
  }

  private static func approvalMode(for metadata: ConversationMetadataSnapshot) -> ApprovalCardMode {
    switch metadata.approval?.type {
      case .question:
        .question
      case .exec, .patch, .permissions:
        metadata.session.sessionId.hasPrefix("codex-") ? .permission : .takeover
      case nil:
        .none
    }
  }
}
