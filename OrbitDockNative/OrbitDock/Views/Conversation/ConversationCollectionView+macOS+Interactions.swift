#if os(macOS)

  import AppKit

  extension ConversationCollectionViewController {
    func toggleThinkingExpansion(messageID: String, row: Int) {
      if expandedThinkingIDs.contains(messageID) {
        expandedThinkingIDs.remove(messageID)
      } else {
        expandedThinkingIDs.insert(messageID)
      }

      guard row < currentRows.count else { return }
      let rowID = currentRows[row].id
      heightEngine.invalidate(rowID: rowID)

      NSAnimationContext.runAnimationGroup { context in
        context.allowsImplicitAnimation = true
        context.duration = 0.2
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
      }

      if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NativeRichMessageCellView,
         let timelineRow = row < currentRows.count ? currentRows[row] : nil,
         let model = rowContext.richMessageModel(for: timelineRow)
      {
        let width = max(100, tableView.bounds.width)
        cell.configure(model: model, width: width)
      }
    }

    func setToolRowExpansion(messageID: String, expanded: Bool) {
      let isExpanded = uiState.expandedToolCards.contains(messageID)
      guard isExpanded != expanded else { return }
      ConversationTimelineReducer.reduce(source: &sourceState, ui: &uiState, action: .toggleToolCard(messageID))
      applyProjectionUpdate(preserveAnchor: true)
    }

    func toggleRollup(id: String) {
      ConversationTimelineReducer.reduce(source: &sourceState, ui: &uiState, action: .toggleRollup(id))
      applyProjectionUpdate(preserveAnchor: true)
    }

    func toggleTurnExpansion(turnID: String) {
      ConversationTimelineReducer.reduce(source: &sourceState, ui: &uiState, action: .toggleTurnExpansion(turnID))
      applyProjectionUpdate(preserveAnchor: true)
    }

    func cancelShellCommand(requestID: String) {
      guard let serverState, let sessionId else { return }
      Task {
        if let msg = messagesByID[requestID], msg.toolName?.lowercased() == "task" {
          try? await serverState.stopTask(sessionId, taskId: requestID)
        } else {
          try? await serverState.cancelShell(sessionId, requestId: requestID)
        }
      }
    }
  }

#endif
