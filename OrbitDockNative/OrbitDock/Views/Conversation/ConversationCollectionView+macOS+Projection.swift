#if os(macOS)

  import AppKit
  import os

  extension ConversationCollectionViewController {
    func applyFullState(
      messages: [TranscriptMessage],
      chatViewMode: ChatViewMode,
      isSessionActive: Bool,
      workStatus: Session.WorkStatus,
      currentTool: String?,
      pendingToolName: String?,
      pendingPermissionDetail: String?,
      currentPrompt: String?,
      messageCount: Int,
      remainingLoadCount: Int,
      hasMoreMessages: Bool
    ) {
      let resolvedMessages = sanitizedConversationMessages(
        messages,
        sessionId: self.sessionId,
        source: "timeline-apply-macos"
      )

      let observable = sessionId.flatMap { serverState?.session($0) }
      let resolvedApprovalId = observable?.pendingApprovalId
      let approvalMode: ApprovalCardMode = {
        guard let observable else { return .none }
        return ApprovalCardModeResolver.resolve(
          for: observable.approvalCardContext,
          pendingApprovalId: resolvedApprovalId,
          approvalType: nil
        )
      }()
      let shouldShowApprovalCard = approvalMode != .none

      let metadata = ConversationSourceState.SessionMetadata(
        chatViewMode: chatViewMode,
        isSessionActive: isSessionActive,
        workStatus: workStatus,
        currentTool: observable?.lastTool ?? currentTool,
        pendingToolName: observable?.pendingToolName ?? pendingToolName,
        pendingApprovalCommand: String.shellCommandDisplay(from: observable?.pendingToolInput),
        pendingPermissionDetail: observable?.pendingPermissionDetail ?? pendingPermissionDetail,
        currentPrompt: currentPrompt,
        messageCount: messageCount,
        remainingLoadCount: remainingLoadCount,
        hasMoreMessages: hasMoreMessages,
        needsApprovalCard: shouldShowApprovalCard,
        approvalMode: approvalMode,
        pendingQuestion: observable?.pendingQuestion,
        pendingApprovalId: resolvedApprovalId,
        isDirectSession: observable?.isDirect ?? false,
        isDirectCodexSession: observable?.isDirectCodex ?? false,
        supportsRichToolingCards: observable?.isDirect ?? false,
        sessionId: self.sessionId,
        projectPath: observable?.projectPath
      )
      ConversationTimelineReducer.reduce(source: &sourceState, ui: &uiState, action: .setSessionMetadata(metadata))
      ConversationTimelineReducer.reduce(source: &sourceState, ui: &uiState, action: .setMessages(resolvedMessages))

      messagesByID = Dictionary(uniqueKeysWithValues: sourceState.messages.map { ($0.id, $0) })
      refreshRowContextCaches()

      if isLoadingMoreAtTop, sourceState.messages.count > loadMoreBaselineMessageCount || !hasMoreMessages {
        isLoadingMoreAtTop = false
      }

      rebuildTurns()
      ConversationTimelineReducer.reduce(
        source: &sourceState,
        ui: &uiState,
        action: .setPinnedToBottom(isPinnedToBottom)
      )
    }

    func rebuildSnapshot(animated: Bool = false) {
      let previousProjection = projectionResult
      projectionResult = makeProjectionResult(previous: previousProjection)
      currentRows = projectionResult.rows
      rebuildRowLookup()
      heightEngine.prune(validRowIDs: Set(projectionResult.rows.map(\.id)))
      tableView.reloadData()
      if !currentRows.isEmpty {
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0 ..< currentRows.count))
      }
    }

    func applyProjectionUpdate(preserveAnchor: Bool = false) {
      let previous = projectionResult
      let next = makeProjectionResult(previous: previous)
      let structureChanged = currentRows.map(\.id) != next.rows.map(\.id)

      if structureChanged {
        applyStructuralProjectionUpdate(
          from: previous,
          to: next,
          newRows: next.rows,
          preserveAnchor: preserveAnchor
        )
      } else {
        applyContentProjectionUpdate(next)
      }

      if isPinnedToBottom {
        requestPinnedScroll()
      }
    }

    private func rebuildTurns() {
      guard sourceState.metadata.chatViewMode == .focused, let serverState else {
        ConversationTimelineReducer.reduce(source: &sourceState, ui: &uiState, action: .setTurns([]))
        turnsByID = [:]
        return
      }

      let serverDiffs = sessionId.flatMap { serverState.session($0).turnDiffs } ?? []
      let turns = TurnBuilder.build(
        from: sourceState.messages,
        serverTurnDiffs: serverDiffs,
        currentTurnId: sourceState.metadata.isSessionActive
          && sourceState.metadata.workStatus == .working ? "active" : nil
      )
      ConversationTimelineReducer.reduce(source: &sourceState, ui: &uiState, action: .setTurns(turns))
      turnsByID = Dictionary(uniqueKeysWithValues: sourceState.turns.map { ($0.id, $0) })
    }

    private func makeProjectionResult(previous: ProjectionResult) -> ProjectionResult {
      let projectionState = signposter.beginInterval("timeline-projection")
      defer {
        signposter.endInterval("timeline-projection", projectionState)
      }
      return ConversationTimelineProjector.project(
        source: sourceState,
        ui: uiState,
        previous: previous
      )
    }

    private func rebuildRowLookup() {
      rowIndexByTimelineRowID.removeAll(keepingCapacity: true)
      for (index, row) in currentRows.enumerated() {
        rowIndexByTimelineRowID[row.id] = index
      }
    }

    private func applyStructuralProjectionUpdate(
      from previous: ProjectionResult,
      to next: ProjectionResult,
      newRows: [TimelineRow],
      preserveAnchor: Bool = false
    ) {
      let applyState = signposter.beginInterval("timeline-apply-structural")
      defer {
        signposter.endInterval("timeline-apply-structural", applyState)
      }
      let diff = next.diff
      let oldIDs = previous.rows.map(\.id)
      let newIDs = next.rows.map(\.id)
      let hasPureReorder = diff.insertions.isEmpty && diff.deletions.isEmpty && oldIDs != newIDs
      let supportsBatchUpdates = !previous.rows.isEmpty && !hasPureReorder
      let shouldPreserveAnchor = !isPinnedToBottom
        && (preserveAnchor || isPrependTransition(from: previous.rows, to: next.rows))

      if shouldPreserveAnchor, let anchor = captureTopVisibleAnchor(rows: previous.rows) {
        ConversationTimelineReducer.reduce(source: &sourceState, ui: &uiState, action: .setScrollAnchor(anchor))
      }

      projectionResult = next
      currentRows = newRows
      rebuildRowLookup()

      guard supportsBatchUpdates else {
        heightEngine.invalidateAll()
        tableView.reloadData()
        if !currentRows.isEmpty {
          tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0 ..< currentRows.count))
        }
        if shouldPreserveAnchor {
          restoreScrollAnchorFromState()
        }
        return
      }

      heightEngine.prune(validRowIDs: Set(projectionResult.rows.map(\.id)))

      tableView.beginUpdates()
      if !diff.deletions.isEmpty {
        tableView.removeRows(at: IndexSet(diff.deletions), withAnimation: [.effectFade])
      }
      if !diff.insertions.isEmpty {
        tableView.insertRows(at: IndexSet(diff.insertions), withAnimation: [.effectFade])
      }
      tableView.endUpdates()

      let reloadRows = IndexSet(diff.reloads.filter { $0 >= 0 && $0 < currentRows.count })
      if !reloadRows.isEmpty {
        invalidateHeightCache(forRows: reloadRows)
        tableView.reloadData(forRowIndexes: reloadRows, columnIndexes: IndexSet(integer: 0))
      }

      let dirtyRows = rowIndexes(forDirtyRowIDs: next.dirtyRowIDs).union(reloadRows)
      if !dirtyRows.isEmpty {
        invalidateHeightCache(forRows: dirtyRows)
        noteHeightChangesWithScrollCompensation(rows: dirtyRows)
      }

      if shouldPreserveAnchor {
        restoreScrollAnchorFromState()
      }
    }

    private func applyContentProjectionUpdate(_ next: ProjectionResult) {
      let applyState = signposter.beginInterval("timeline-apply-content")
      defer {
        signposter.endInterval("timeline-apply-content", applyState)
      }
      projectionResult = next
      currentRows = next.rows

      let reloadRows = IndexSet(next.diff.reloads.filter { $0 >= 0 && $0 < currentRows.count })
      if !reloadRows.isEmpty {
        invalidateHeightCache(forRows: reloadRows)
        tableView.reloadData(forRowIndexes: reloadRows, columnIndexes: IndexSet(integer: 0))
      }

      let dirtyRows = rowIndexes(forDirtyRowIDs: next.dirtyRowIDs).union(reloadRows)
      if !dirtyRows.isEmpty {
        invalidateHeightCache(forRows: dirtyRows)
        noteHeightChangesWithScrollCompensation(rows: dirtyRows)
      }
    }

    private func rowIndexes(forDirtyRowIDs ids: Set<TimelineRowID>) -> IndexSet {
      guard !ids.isEmpty else { return [] }
      var indexes = IndexSet()
      for id in ids {
        if let index = rowIndexByTimelineRowID[id] {
          indexes.insert(index)
        }
      }
      return indexes
    }

    private func invalidateHeightCache(forRows rows: IndexSet) {
      guard !rows.isEmpty else { return }
      for row in rows {
        guard row >= 0, row < currentRows.count else { continue }
        let timelineRow = currentRows[row]
        if let key = heightCacheKey(forRow: row), heightEngine.height(for: key) != nil {
          continue
        }
        heightEngine.invalidate(rowID: timelineRow.id)
      }
    }

    private func rowID(forRow row: Int) -> TimelineRowID? {
      guard row >= 0, row < currentRows.count else { return nil }
      return currentRows[row].id
    }

    func heightCacheKey(forRow row: Int) -> HeightCacheKey? {
      guard row >= 0, row < currentRows.count else { return nil }
      let timelineRow = currentRows[row]
      return HeightCacheKey(
        rowID: timelineRow.id,
        widthBucket: uiState.widthBucket,
        layoutHash: timelineRow.layoutHash
      )
    }
  }

#endif
