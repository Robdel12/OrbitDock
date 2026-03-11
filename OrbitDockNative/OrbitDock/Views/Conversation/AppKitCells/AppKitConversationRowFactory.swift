#if os(macOS)

  import AppKit

  struct AppKitConversationRowContext {
    let rows: [TimelineRow]
    let messagesByID: [String: TranscriptMessage]
    let turnsByID: [String: TurnSummary]
    let subagentsByID: [String: ServerSubagentInfo]
    let metadata: ConversationSourceState.SessionMetadata
    let uiState: ConversationUIState
    let selectedWorkerID: String?
    let approvalCardModel: ApprovalCardModel?
    let expandedThinkingIDs: Set<String>
    let rowWidth: CGFloat
    let tableWidth: CGFloat
  }

  extension AppKitConversationRowContext {
    func richMessageModel(for row: TimelineRow) -> NativeRichMessageRowModel? {
      guard case let .message(id, showHeader) = row.payload else { return nil }
      guard let message = messagesByID[id] else { return nil }

      return SharedModelBuilders.richMessageModel(
        from: message,
        messageID: id,
        isThinkingExpanded: expandedThinkingIDs.contains(id),
        showHeader: showHeader
      )
    }

    func compactToolModel(for row: TimelineRow) -> NativeCompactToolRowModel? {
      guard case let .tool(id) = row.payload else { return nil }
      guard !uiState.expandedToolCards.contains(id) else { return nil }
      guard let message = messagesByID[id] else { return nil }

      return SharedModelBuilders.compactToolModel(
        from: message,
        supportsRichToolingCards: metadata.supportsRichToolingCards,
        subagentsByID: subagentsByID,
        selectedWorkerID: selectedWorkerID
      )
    }

    func workerEventModel(for row: TimelineRow) -> NativeCompactToolRowModel? {
      guard case let .workerEvent(id) = row.payload else { return nil }
      guard let message = messagesByID[id] else { return nil }

      return SharedModelBuilders.workerEventModel(
        from: message,
        subagentsByID: subagentsByID,
        selectedWorkerID: selectedWorkerID
      )
    }

    func expandedToolModel(for row: TimelineRow) -> NativeExpandedToolModel? {
      guard case let .tool(id) = row.payload else { return nil }
      guard uiState.expandedToolCards.contains(id) else { return nil }
      guard let message = messagesByID[id] else { return nil }

      return SharedModelBuilders.expandedToolModel(
        from: message,
        messageID: id,
        supportsRichToolingCards: metadata.supportsRichToolingCards,
        subagentsByID: subagentsByID
      )
    }

    func workerOrchestrationModel(for row: TimelineRow) -> ConversationUtilityRowModels.WorkerOrchestrationModel? {
      guard case let .workerOrchestration(_, workerIDs) = row.payload else { return nil }
      return ConversationUtilityRowModels.workerOrchestration(
        workerIDs: workerIDs,
        subagentsByID: subagentsByID
      )
    }

    func cardPosition(for row: Int) -> CardPosition {
      ConversationTimelineLayoutHelpers.cardPosition(for: row, rows: rows) { [messagesByID] messageID in
        messagesByID[messageID]
      }
    }

    func cardSpacing(for row: Int) -> (topInset: CGFloat, bottomInset: CGFloat, heightExtra: CGFloat) {
      let spacing = ConversationTimelineLayoutHelpers.cardSpacing(for: row, rows: rows) { [messagesByID] messageID in
        messagesByID[messageID]
      }
      return (spacing.topInset, spacing.bottomInset, spacing.heightExtra)
    }
  }

  struct AppKitConversationRowHandlers {
    let toggleThinkingExpansion: (String, Int) -> Void
    let expandToolRow: (String) -> Void
    let collapseToolRow: (String) -> Void
    let cancelShellCommand: (String) -> Void
    let toggleRollup: (String) -> Void
    let toggleTurnExpansion: (String) -> Void
    let focusWorkerInDeck: (String) -> Void
    let loadMore: (() -> Void)?
    let openPendingApprovalPanel: (() -> Void)?
  }

  enum AppKitConversationRowFactory {
    static func makeView(
      tableView: NSTableView,
      row: Int,
      context: AppKitConversationRowContext,
      handlers: AppKitConversationRowHandlers,
      logger: TimelineFileLogger
    ) -> NSView? {
      guard row >= 0, row < context.rows.count else { return nil }
      let timelineRow = context.rows[row]
      let width = context.rowWidth

      switch timelineRow.kind {
        case .bottomSpacer:
          let id = NativeSpacerCellView.reuseIdentifier
          let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NativeSpacerCellView)
            ?? NativeSpacerCellView(frame: .zero)
          cell.identifier = id
          return cell

        case .approvalCard:
          if let model = context.approvalCardModel {
            let id = NativeApprovalCardCellView.reuseIdentifier
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NativeApprovalCardCellView)
              ?? NativeApprovalCardCellView(frame: .zero)
            cell.identifier = id
            cell.onTap = handlers.openPendingApprovalPanel
            cell.configure(model: model)
            return cell
          }
          return NativeSpacerCellView(frame: .zero)

        case .turnHeader:
          if case let .turnHeader(turnID, turnNumber, _) = timelineRow.payload {
            let id = NativeTurnHeaderCellView.reuseIdentifier
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NativeTurnHeaderCellView)
              ?? NativeTurnHeaderCellView(frame: .zero)
            cell.identifier = id
            let model: ConversationUtilityRowModels.TurnHeaderModel
            if let turn = context.turnsByID[turnID] {
              model = ConversationUtilityRowModels.turnHeader(for: turn)
            } else {
              model = ConversationUtilityRowModels.TurnHeaderModel(
                labelText: turnNumber > 1 ? "TURN \(turnNumber)" : nil,
                toolsText: nil
              )
            }
            cell.configure(model: model)
            return cell
          }

        case .rollupSummary:
          if case let .rollupSummary(rollupID, hiddenCount, totalToolCount, isExpanded, breakdown, hiddenMessageIDs) =
            timelineRow.payload
          {
            let id = NativeRollupSummaryCellView.reuseIdentifier
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NativeRollupSummaryCellView)
              ?? NativeRollupSummaryCellView(frame: .zero)
            cell.identifier = id
            let groupMessages = hiddenMessageIDs.compactMap { context.messagesByID[$0] }
            let model = ConversationUtilityRowModels.rollupSummary(
              hiddenCount: hiddenCount,
              totalToolCount: totalToolCount,
              isExpanded: isExpanded,
              breakdown: breakdown,
              messages: groupMessages
            )
            cell.configure(model: model)
            cell.onToggle = { handlers.toggleRollup(rollupID) }
            return cell
          }

        case .loadMore:
          let id = NativeLoadMoreCellView.reuseIdentifier
          let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NativeLoadMoreCellView)
            ?? NativeLoadMoreCellView(frame: .zero)
          cell.identifier = id
          cell.configure(remainingCount: context.metadata.remainingLoadCount)
          cell.onLoadMore = handlers.loadMore
          return cell

        case .messageCount:
          let id = NativeMessageCountCellView.reuseIdentifier
          let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NativeMessageCountCellView)
            ?? NativeMessageCountCellView(frame: .zero)
          cell.identifier = id
          cell.configure(displayedCount: context.messagesByID.count, totalCount: context.metadata.messageCount)
          return cell

        case .liveIndicator:
          let id = NativeLiveIndicatorCellView.reuseIdentifier
          let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NativeLiveIndicatorCellView)
            ?? NativeLiveIndicatorCellView(frame: .zero)
          cell.identifier = id
          let model = ConversationUtilityRowModels.liveIndicator(
            workStatus: context.metadata.workStatus,
            currentTool: context.metadata.currentTool,
            pendingToolName: context.metadata.pendingToolName
          )
          cell.configure(model: model)
          return cell

        case .workerOrchestration:
          if let model = context.workerOrchestrationModel(for: timelineRow) {
            let id = NativeWorkerOrchestrationCellView.reuseIdentifier
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NativeWorkerOrchestrationCellView)
              ?? NativeWorkerOrchestrationCellView(frame: .zero)
            cell.identifier = id
            cell.onSelectWorker = handlers.focusWorkerInDeck
            cell.configure(model: model)
            return cell
          }

        case .workerEvent:
          if let workerModel = context.workerEventModel(for: timelineRow) {
            let id = NativeCompactToolCellView.reuseIdentifier
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NativeCompactToolCellView)
              ?? NativeCompactToolCellView(frame: .zero)
            cell.identifier = id
            cell.configure(model: workerModel)
            cell.onFocusWorker = {
              if let workerID = workerModel.linkedWorkerID {
                handlers.focusWorkerInDeck(workerID)
              }
            }
            cell.onTap = {
              if let workerID = workerModel.linkedWorkerID {
                handlers.focusWorkerInDeck(workerID)
              }
            }
            return cell
          }

        case .tool:
          if let toolModel = context.compactToolModel(for: timelineRow) {
            let id = NativeCompactToolCellView.reuseIdentifier
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NativeCompactToolCellView)
              ?? NativeCompactToolCellView(frame: .zero)
            cell.identifier = id
            cell.configure(model: toolModel)
            cell.onFocusWorker = {
              if let workerID = toolModel.linkedWorkerID {
                handlers.focusWorkerInDeck(workerID)
              }
            }
            if case let .tool(messageID) = timelineRow.payload {
              cell.onTap = {
                handlers.expandToolRow(messageID)
              }
            }
            return cell
          }

        case .liveProgress:
          if case let .liveProgress(currentTool, completedCount, elapsedTime) = timelineRow.payload {
            let id = NativeLiveProgressCellView.reuseIdentifier
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NativeLiveProgressCellView)
              ?? NativeLiveProgressCellView(frame: .zero)
            cell.identifier = id
            let model = ConversationUtilityRowModels.liveProgress(
              currentTool: currentTool,
              completedCount: completedCount,
              elapsedTime: elapsedTime
            )
            cell.configure(model: model)
            return cell
          }

        case .collapsedTurn:
          if case let .collapsedTurn(turnID, userPreview, assistantPreview, toolCount, totalDuration) = timelineRow.payload {
            let id = NativeCollapsedTurnCellView.reuseIdentifier
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NativeCollapsedTurnCellView)
              ?? NativeCollapsedTurnCellView(frame: .zero)
            cell.identifier = id
            let model = ConversationUtilityRowModels.collapsedTurn(
              userPreview: userPreview,
              assistantPreview: assistantPreview,
              toolCount: toolCount,
              totalDuration: totalDuration
            )
            cell.configure(model: model)
            cell.onTap = { handlers.toggleTurnExpansion(turnID) }
            return cell
          }

        default:
          break
      }

      if let richModel = context.richMessageModel(for: timelineRow) {
        let richID = NativeRichMessageCellView.reuseIdentifier
        let richCell = (tableView.makeView(withIdentifier: richID, owner: nil) as? NativeRichMessageCellView)
          ?? NativeRichMessageCellView(frame: .zero)
        richCell.identifier = richID
        richCell.onThinkingExpandToggle = { messageID in
          handlers.toggleThinkingExpansion(messageID, row)
        }
        richCell.configure(model: richModel, width: width)
        logger.debug("viewFor[\(row)] \(timelineRow.id.rawValue) native-rich w=\(String(format: "%.0f", width))")
        return richCell
      }

      if let expandedModel = context.expandedToolModel(for: timelineRow) {
        let expandedID = NativeExpandedToolCellView.reuseIdentifier
        let expandedCell = (tableView.makeView(withIdentifier: expandedID, owner: nil) as? NativeExpandedToolCellView)
          ?? NativeExpandedToolCellView(frame: .zero)
        expandedCell.identifier = expandedID
        expandedCell.onCollapse = { messageID in
          handlers.collapseToolRow(messageID)
        }
        expandedCell.onCancel = { requestID in
          handlers.cancelShellCommand(requestID)
        }
        expandedCell.onFocusWorker = { workerID in
          handlers.focusWorkerInDeck(workerID)
        }
        expandedCell.configure(model: expandedModel, width: width)
        logger.debug("viewFor[\(row)] \(timelineRow.id.rawValue) native-expanded-tool w=\(String(format: "%.0f", width))")
        return expandedCell
      }

      let id = NativeSpacerCellView.reuseIdentifier
      let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NativeSpacerCellView)
        ?? NativeSpacerCellView(frame: .zero)
      cell.identifier = id
      logger.debug("viewFor[\(row)] \(timelineRow.id.rawValue) clear-fallback")
      return cell
    }

    static func makeRowView(tableView: NSTableView, row: Int, context: AppKitConversationRowContext) -> NSTableRowView {
      guard row >= 0, row < context.rows.count else {
        let id = NSUserInterfaceItemIdentifier("conversationClearRowView")
        let rv = (tableView.makeView(withIdentifier: id, owner: nil) as? ClearTableRowView)
          ?? ClearTableRowView(frame: .zero)
        rv.identifier = id
        return rv
      }

      let position = context.cardPosition(for: row)
      if position != .none {
        let id = NSUserInterfaceItemIdentifier("conversationCardRowView")
        let cardView = (tableView.makeView(withIdentifier: id, owner: nil) as? CardTableRowView)
          ?? CardTableRowView(frame: .zero)
        cardView.identifier = id
        cardView.cardPosition = position
        let insets = context.cardSpacing(for: row)
        cardView.cardTopInset = insets.topInset
        cardView.cardBottomInset = insets.bottomInset
        return cardView
      }

      let id = NSUserInterfaceItemIdentifier("conversationClearRowView")
      let rv = (tableView.makeView(withIdentifier: id, owner: nil) as? ClearTableRowView)
        ?? ClearTableRowView(frame: .zero)
      rv.identifier = id
      return rv
    }

    static func height(
      for row: Int,
      context: AppKitConversationRowContext,
      measurementWidth: CGFloat
    ) -> CGFloat {
      guard row >= 0, row < context.rows.count else { return 1 }
      let timelineRow = context.rows[row]
      let spacing = context.cardSpacing(for: row)

      switch timelineRow.kind {
        case .bottomSpacer:
          return ConversationLayout.bottomSpacerHeight
        case .turnHeader:
          return ConversationTimelineLayoutHelpers.turnHeaderHeight(for: timelineRow)
        case .loadMore:
          return ConversationLayout.loadMoreHeight
        case .messageCount:
          return ConversationLayout.messageCountHeight
        case .rollupSummary:
          return ConversationLayout.activityCapsuleHeight + spacing.heightExtra
        case .approvalCard:
          return NativeApprovalCardCellView.requiredHeight(
            for: context.approvalCardModel,
            availableWidth: context.tableWidth
          )
        case .liveIndicator:
          return ConversationLayout.liveIndicatorHeight
        case .workerOrchestration:
          return ConversationLayout.workerOrchestrationHeight + spacing.heightExtra
        case .workerEvent:
          if let workerModel = context.workerEventModel(for: timelineRow) {
            let compactHeight = NativeCompactToolCellView.requiredHeight(
              model: workerModel,
              width: context.tableWidth
            )
            return compactHeight + spacing.heightExtra
          }
        case .liveProgress:
          return ConversationLayout.liveProgressHeight + spacing.heightExtra
        case .collapsedTurn:
          return ConversationLayout.collapsedTurnHeight
        case .tool:
          if let compactModel = context.compactToolModel(for: timelineRow) {
            let compactHeight = NativeCompactToolCellView.requiredHeight(
              model: compactModel,
              width: context.tableWidth
            )
            return compactHeight + spacing.heightExtra
          }
        default:
          break
      }

      if let richModel = context.richMessageModel(for: timelineRow) {
        let measuredHeight = max(
          1,
          ceil(NativeRichMessageCellView.requiredHeight(for: measurementWidth, model: richModel))
        )
        return measuredHeight + spacing.heightExtra
      }

      if let expandedModel = context.expandedToolModel(for: timelineRow) {
        let measuredHeight = max(
          1,
          ceil(NativeExpandedToolCellView.requiredHeight(for: measurementWidth, model: expandedModel))
        )
        return measuredHeight + spacing.heightExtra
      }

      return 1
    }
  }

#endif
