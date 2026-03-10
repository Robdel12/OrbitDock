#if os(iOS)

  import UIKit

  extension ConversationCollectionViewController {
    func toggleThinkingExpansion(messageID: String) {
      if expandedThinkingIDs.contains(messageID) {
        expandedThinkingIDs.remove(messageID)
      } else {
        expandedThinkingIDs.insert(messageID)
      }
      Platform.services.playHaptic(.expansion)
      let rowID = TimelineRowID.message(messageID)
      heightCache.removeValue(forKey: rowID)
      var snapshot = dataSource.snapshot()
      snapshot.reconfigureItems([rowID])
      dataSource.apply(snapshot, animatingDifferences: true) { [weak self] in
        guard let self else { return }
        collectionView.collectionViewLayout.invalidateLayout()
        collectionView.layoutIfNeeded()
      }
    }

    func toggleToolExpansion(messageID: String) {
      let wasExpanded = uiState.expandedToolCards.contains(messageID)
      ConversationTimelineReducer.reduce(source: &sourceState, ui: &uiState, action: .toggleToolCard(messageID))
      logger.debug("toggleToolExpansion[\(messageID.prefix(8))] \(wasExpanded ? "collapse" : "expand")")
      Platform.services.playHaptic(.expansion)

      let toolRowID = currentRows.first(where: {
        if case let .tool(id) = $0.payload { return id == messageID }
        return false
      })?.id
      if let toolRowID { heightCache.removeValue(forKey: toolRowID) }

      rebuildSnapshot(animated: false)
      if let toolRowID {
        var snapshot = dataSource.snapshot()
        snapshot.reloadItems([toolRowID])
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
          guard let self else { return }
          collectionView.collectionViewLayout.invalidateLayout()
          collectionView.layoutIfNeeded()
        }
      } else {
        collectionView.collectionViewLayout.invalidateLayout()
        collectionView.layoutIfNeeded()
      }
    }

    func toggleRollup(id: String) {
      ConversationTimelineReducer.reduce(source: &sourceState, ui: &uiState, action: .toggleRollup(id))
      Platform.services.playHaptic(.expansion)
      applyProjectionUpdate()
    }

    func toggleTurnExpansion(turnID: String) {
      ConversationTimelineReducer.reduce(source: &sourceState, ui: &uiState, action: .toggleTurnExpansion(turnID))
      Platform.services.playHaptic(.expansion)
      applyProjectionUpdate()
    }

    func cancelShellCommand(requestID: String) {
      guard let serverState, let sessionId else { return }
      Task { @MainActor in
        do {
          if let msg = messagesByID[requestID], msg.toolName?.lowercased() == "task" {
            try await serverState.stopTask(sessionId, taskId: requestID)
          } else {
            try await serverState.cancelShell(sessionId, requestId: requestID)
          }
        } catch {
          netLog(
            .error,
            cat: .conv,
            "Cancel shell command failed",
            sid: sessionId,
            data: ["requestId": requestID, "error": error.localizedDescription]
          )
        }
      }
    }
  }

#endif
