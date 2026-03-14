#if os(iOS)

  import UIKit

  extension ConversationCollectionViewController {
    func scrollToConversationMessage(_ messageID: String, animated: Bool) {
      guard let rowID = timelineRowID(for: messageID),
            let row = rowIndexByTimelineRowID[rowID]
      else { return }

      let indexPath = IndexPath(item: row, section: 0)
      guard collectionView.numberOfItems(inSection: 0) > row else { return }
      collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: animated)
      coordinator?.pinnedChanged(false)
      coordinator?.unreadReset()
    }

    private func timelineRowID(for messageID: String) -> TimelineRowID? {
      let candidates: [TimelineRowID] = [
        .workerEvent(messageID),
        .tool(messageID),
        .message(messageID),
      ]

      return candidates.first(where: { rowIndexByTimelineRowID[$0] != nil })
    }

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
      let wasExpanded = expandedToolCardIDs.contains(messageID)
      if wasExpanded {
        expandedToolCardIDs.remove(messageID)
      } else {
        expandedToolCardIDs.insert(messageID)
      }
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
      if expandedActivityGroupIDs.contains(id) {
        expandedActivityGroupIDs.remove(id)
      } else {
        expandedActivityGroupIDs.insert(id)
      }
      Platform.services.playHaptic(.expansion)
      heightCache.removeAll()
      rebuildSnapshot(animated: false)
      collectionView.collectionViewLayout.invalidateLayout()
      collectionView.layoutIfNeeded()
    }

    func toggleTurnExpansion(turnID: String) {
      Platform.services.playHaptic(.expansion)
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
