#if os(iOS)

  import UIKit

  extension ConversationCollectionViewController {
    func setupCellRegistrations() {
      messageCellReg = UICollectionView.CellRegistration<UIKitRichMessageCell, String> {
        [weak self] cell, indexPath, _ in
        guard let self else { return }
        guard indexPath.item < currentRows.count else { return }
        guard let model = buildRichMessageModel(for: currentRows[indexPath.item]) else { return }
        cell.configure(model: model, width: collectionView.bounds.width)
        cell.onThinkingExpandToggle = { [weak self] id in
          self?.toggleThinkingExpansion(messageID: id)
        }
      }

      compactToolCellReg = UICollectionView.CellRegistration<UIKitCompactToolCell, String> {
        [weak self] cell, _, messageId in
        guard let self else { return }
        guard let model = buildCompactToolModel(for: messageId) else { return }
        cell.configure(model: model)
        cell.onFocusWorker = { [weak self] in
          guard let workerID = model.linkedWorkerID else { return }
          self?.focusWorkerInDeck?(workerID)
        }
        cell.onTap = { [weak self] in
          self?.toggleToolExpansion(messageID: messageId)
        }
      }

      expandedToolCellReg = UICollectionView.CellRegistration<UIKitExpandedToolCell, String> {
        [weak self] cell, _, messageId in
        guard let self else { return }
        guard let model = buildExpandedToolModel(for: messageId) else { return }
        cell.configure(model: model, width: collectionView.bounds.width)
        cell.onCollapse = { [weak self] id in
          self?.toggleToolExpansion(messageID: id)
        }
        cell.onCancel = { [weak self] requestID in
          self?.cancelShellCommand(requestID: requestID)
        }
        cell.onFocusWorker = { [weak self] workerID in
          self?.focusWorkerInDeck?(workerID)
        }
      }

      turnHeaderCellReg = UICollectionView.CellRegistration<UIKitTurnHeaderCell, String> {
        [weak self] cell, _, turnId in
        guard let self, let model = buildTurnHeaderModel(for: turnId) else { return }
        cell.configure(model: model)
      }

      rollupSummaryCellReg = UICollectionView.CellRegistration<UIKitRollupSummaryCell, String> {
        [weak self] cell, _, rollupId in
        guard let self, let model = buildRollupSummaryModel(for: rollupId) else { return }
        cell.configure(model: model)
        cell.onToggle = { [weak self] in
          self?.toggleRollup(id: rollupId)
        }
      }

      loadMoreCellReg = UICollectionView.CellRegistration<UIKitLoadMoreCell, Void> {
        [weak self] cell, _, _ in
        guard let self else { return }
        cell.configure(remainingCount: sourceState.metadata.remainingLoadCount)
        cell.onLoadMore = onLoadMore
      }

      messageCountCellReg = UICollectionView.CellRegistration<UIKitMessageCountCell, Void> {
        [weak self] cell, _, _ in
        guard let self else { return }
        cell.configure(
          displayedCount: sourceState.messages.count,
          totalCount: sourceState.metadata.messageCount
        )
      }

      liveIndicatorCellReg = UICollectionView.CellRegistration<UIKitLiveIndicatorCell, Void> {
        [weak self] cell, _, _ in
        guard let self else { return }
        cell.configure(model: buildLiveIndicatorModel())
      }

      workerEventCellReg = UICollectionView.CellRegistration<UIKitCompactToolCell, String> {
        [weak self] cell, indexPath, _ in
        guard let self else { return }
        guard indexPath.item < currentRows.count else { return }
        guard let model = buildWorkerEventModel(for: currentRows[indexPath.item]) else { return }
        cell.configure(model: model)
        cell.onFocusWorker = { [weak self] in
          guard let workerID = model.linkedWorkerID else { return }
          self?.focusWorkerInDeck?(workerID)
        }
        cell.onTap = { [weak self] in
          guard let workerID = model.linkedWorkerID else { return }
          self?.focusWorkerInDeck?(workerID)
        }
      }

      workerOrchestrationCellReg = UICollectionView.CellRegistration<UIKitWorkerOrchestrationCell, String> {
        [weak self] cell, indexPath, turnID in
        guard let self else { return }
        guard indexPath.item < currentRows.count else { return }
        guard let model = buildWorkerOrchestrationModel(for: currentRows[indexPath.item]) else { return }
        cell.configure(model: model)
        cell.onSelectWorker = { [weak self] workerID in
          self?.focusWorkerInDeck?(workerID)
        }
      }

      liveProgressCellReg = UICollectionView.CellRegistration<UIKitLiveProgressCell, Void> {
        [weak self] cell, indexPath, _ in
        guard let self else { return }
        guard indexPath.item < currentRows.count else { return }
        guard let model = buildLiveProgressModel(for: currentRows[indexPath.item]) else { return }
        cell.configure(model: model)
      }

      approvalCardCellReg = UICollectionView.CellRegistration<UIKitApprovalCardCell, Void> {
        [weak self] cell, _, _ in
        guard let self, let model = buildApprovalCardModel() else { return }
        cell.onTap = onOpenPendingApprovalPanel
        cell.configure(model: model)
      }

      collapsedTurnCellReg = UICollectionView.CellRegistration<UIKitCollapsedTurnCell, String> {
        [weak self] cell, _, turnId in
        guard let self, let model = buildCollapsedTurnModel(for: turnId) else { return }
        cell.configure(model: model)
        cell.onTap = { [weak self] in
          self?.toggleTurnExpansion(turnID: turnId)
        }
      }

      spacerCellReg = UICollectionView.CellRegistration<UIKitSpacerCell, Void> { _, _, _ in
      }
    }

    func setupDataSource() {
      dataSource = UICollectionViewDiffableDataSource<ConversationSection, TimelineRowID>(
        collectionView: collectionView
      ) { [weak self] collectionView, indexPath, _ in
        guard let self else { return UICollectionViewCell() }
        guard indexPath.item < currentRows.count else { return UICollectionViewCell() }
        guard let cell = dequeueCell(in: collectionView, at: indexPath, row: currentRows[indexPath.item]) else {
          return UICollectionViewCell()
        }
        applyCardPosition(to: cell, at: indexPath)
        return cell
      }
    }

    private func dequeueCell(
      in collectionView: UICollectionView,
      at indexPath: IndexPath,
      row: TimelineRow
    ) -> UICollectionViewCell? {
      switch row.kind {
        case .loadMore:
          return collectionView.dequeueConfiguredReusableCell(
            using: loadMoreCellReg, for: indexPath, item: ()
          )
        case .messageCount:
          return collectionView.dequeueConfiguredReusableCell(
            using: messageCountCellReg, for: indexPath, item: ()
          )
        case .message:
          guard case let .message(id, _) = row.payload else { return nil }
          return collectionView.dequeueConfiguredReusableCell(
            using: messageCellReg, for: indexPath, item: id
          )
        case .tool:
          guard case let .tool(id) = row.payload else { return nil }
          if uiState.expandedToolCards.contains(id) {
            return collectionView.dequeueConfiguredReusableCell(
              using: expandedToolCellReg, for: indexPath, item: id
            )
          }
          return collectionView.dequeueConfiguredReusableCell(
            using: compactToolCellReg, for: indexPath, item: id
          )
        case .turnHeader:
          guard case let .turnHeader(turnID, _, _) = row.payload else { return nil }
          return collectionView.dequeueConfiguredReusableCell(
            using: turnHeaderCellReg, for: indexPath, item: turnID
          )
        case .rollupSummary:
          guard case let .rollupSummary(rollupID, _, _, _, _, _) = row.payload else { return nil }
          return collectionView.dequeueConfiguredReusableCell(
            using: rollupSummaryCellReg, for: indexPath, item: rollupID
          )
        case .liveIndicator:
          return collectionView.dequeueConfiguredReusableCell(
            using: liveIndicatorCellReg, for: indexPath, item: ()
          )
        case .workerEvent:
          guard case let .workerEvent(messageID) = row.payload else { return nil }
          return collectionView.dequeueConfiguredReusableCell(
            using: workerEventCellReg, for: indexPath, item: messageID
          )
        case .workerOrchestration:
          guard case let .workerOrchestration(turnID, _) = row.payload else { return nil }
          return collectionView.dequeueConfiguredReusableCell(
            using: workerOrchestrationCellReg, for: indexPath, item: turnID
          )
        case .approvalCard:
          return collectionView.dequeueConfiguredReusableCell(
            using: approvalCardCellReg, for: indexPath, item: ()
          )
        case .bottomSpacer:
          return collectionView.dequeueConfiguredReusableCell(
            using: spacerCellReg, for: indexPath, item: ()
          )
        case .liveProgress:
          return collectionView.dequeueConfiguredReusableCell(
            using: liveProgressCellReg, for: indexPath, item: ()
          )
        case .collapsedTurn:
          guard case let .collapsedTurn(turnID, _, _, _, _) = row.payload else { return nil }
          return collectionView.dequeueConfiguredReusableCell(
            using: collapsedTurnCellReg, for: indexPath, item: turnID
          )
      }
    }
  }

#endif
