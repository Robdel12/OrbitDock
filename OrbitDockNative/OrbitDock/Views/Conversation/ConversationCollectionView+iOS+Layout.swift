#if os(iOS)

  import UIKit

  extension ConversationCollectionViewController: UICollectionViewDelegateFlowLayout, UIScrollViewDelegate {
    fileprivate static func formatHeight(_ value: CGFloat) -> String {
      String(format: "%.1f", value)
    }

    func scrollToBottom(animated: Bool) {
      guard let dataSource, !dataSource.snapshot().itemIdentifiers.isEmpty else { return }
      let items = dataSource.snapshot().itemIdentifiers(inSection: .main)
      guard !items.isEmpty else { return }
      collectionView.scrollToItem(at: IndexPath(item: items.count - 1, section: 0), at: .bottom, animated: animated)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
      if isPinnedToBottom {
        isPinnedToBottom = false
        coordinator?.pinnedChanged(false)
      }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
      if !decelerate {
        checkRepinIfNearBottom(scrollView)
      }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
      checkRepinIfNearBottom(scrollView)
    }

    func collectionView(
      _ collectionView: UICollectionView,
      layout collectionViewLayout: UICollectionViewLayout,
      sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
      let width = collectionView.bounds.width
      guard width > 0 else { return CGSize(width: 1, height: 1) }
      guard indexPath.item < currentRows.count else { return CGSize(width: width, height: 1) }

      let row = currentRows[indexPath.item]
      let spacingExtra = cardSpacingHeightExtra(forItem: indexPath.item)

      if let cached = heightCache[row.id] {
        return CGSize(width: width, height: cached + spacingExtra)
      }

      let height = uncachedHeight(for: row, at: indexPath, width: width)
      heightCache[row.id] = height
      return CGSize(width: width, height: height + spacingExtra)
    }

    private func uncachedHeight(for row: TimelineRow, at indexPath: IndexPath, width: CGFloat) -> CGFloat {
      switch row.kind {
        case .bottomSpacer:
          return ConversationLayout.bottomSpacerHeight
        case .turnHeader:
          return ConversationTimelineLayoutHelpers.turnHeaderHeight(for: row)
        case .rollupSummary:
          return ConversationLayout.activityCapsuleHeight
        case .loadMore:
          return ConversationLayout.loadMoreHeight
        case .messageCount:
          return ConversationLayout.messageCountHeight
        case .tool:
          return toolRowHeight(for: row, at: indexPath, width: width)
        case .message:
          return messageRowHeight(for: row, at: indexPath, width: width)
        case .liveIndicator:
          return ConversationLayout.liveIndicatorHeight
        case .approvalCard:
          return UIKitApprovalCardCell.requiredHeight(for: buildApprovalCardModel(), availableWidth: width)
        case .liveProgress:
          return ConversationLayout.liveProgressHeight
        case .collapsedTurn:
          return ConversationLayout.collapsedTurnHeight
      }
    }

    private func toolRowHeight(for row: TimelineRow, at indexPath: IndexPath, width: CGFloat) -> CGFloat {
      guard case let .tool(id) = row.payload else { return ConversationLayout.compactToolRowHeight }
      if uiState.expandedToolCards.contains(id), let toolModel = buildExpandedToolModel(for: id) {
        let height = ExpandedToolLayout.requiredHeight(for: width, model: toolModel)
        logger.debug("sizeForItem[\(indexPath.item)] tool[\(id.prefix(8))] expanded h=\(Self.formatHeight(height))")
        return height
      }

      let height: CGFloat
      if let message = messagesByID[id] {
        let model = SharedModelBuilders.compactToolModel(
          from: message,
          supportsRichToolingCards: sourceState.metadata.supportsRichToolingCards
        )
        height = UIKitCompactToolCell.requiredHeight(model: model, width: width)
      } else {
        height = ConversationLayout.compactToolRowHeight
      }
      logger.debug("sizeForItem[\(indexPath.item)] tool[\(id.prefix(8))] compact h=\(Self.formatHeight(height))")
      return height
    }

    private func messageRowHeight(for row: TimelineRow, at indexPath: IndexPath, width: CGFloat) -> CGFloat {
      if case let .message(id, _) = row.payload, let model = buildRichMessageModel(for: row) {
        let height = UIKitRichMessageCell.requiredHeight(for: width, model: model)
        logger.debug(
          "sizeForItem[\(indexPath.item)] msg[\(id.prefix(8))] \(model.messageType) "
            + "h=\(Self.formatHeight(height)) w=\(Self.formatHeight(width))"
        )
        return height
      }

      logger.debug("sizeForItem[\(indexPath.item)] msg fallback h=44")
      return 44
    }

    func captureTopVisibleAnchor() -> (rowID: TimelineRowID, delta: Double)? {
      guard !currentRows.isEmpty else { return nil }
      let visiblePaths = collectionView.indexPathsForVisibleItems.sorted()
      guard let topPath = visiblePaths.first else { return nil }
      let row = topPath.item
      guard row >= 0, row < currentRows.count else { return nil }
      guard let rowTopY = collectionView.layoutAttributesForItem(at: topPath)?.frame.minY else { return nil }
      let viewportTopY = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
      let delta = ConversationScrollAnchorMath.captureDelta(viewportTopY: viewportTopY, rowTopY: rowTopY)
      return (rowID: currentRows[row].id, delta: delta)
    }

    func restoreScrollAnchor(_ anchor: (rowID: TimelineRowID, delta: Double)) {
      guard let row = rowIndexByTimelineRowID[anchor.rowID], row >= 0, row < currentRows.count else { return }
      collectionView.layoutIfNeeded()
      let indexPath = IndexPath(item: row, section: 0)
      guard let attrs = collectionView.layoutAttributesForItem(at: indexPath) else { return }
      let insetTop = collectionView.adjustedContentInset.top
      let viewportHeight = collectionView.bounds.height - insetTop - collectionView.adjustedContentInset.bottom
      let targetY = ConversationScrollAnchorMath.restoredViewportTop(
        rowTopY: attrs.frame.minY,
        deltaFromRowTop: anchor.delta,
        contentHeight: collectionView.contentSize.height,
        viewportHeight: viewportHeight
      ) - insetTop
      collectionView.setContentOffset(CGPoint(x: 0, y: targetY), animated: false)
    }

    private func checkRepinIfNearBottom(_ scrollView: UIScrollView) {
      let distanceFromBottom = scrollView.contentSize.height - scrollView.contentOffset.y - scrollView.frame.height
      if distanceFromBottom < 60 {
        isPinnedToBottom = true
        coordinator?.pinnedChanged(true)
        coordinator?.unreadReset()
      }
    }

    private func cardPosition(forItem item: Int) -> CardPosition {
      ConversationTimelineLayoutHelpers.cardPosition(for: item, rows: currentRows) { [messagesByID] messageID in
        messagesByID[messageID]
      }
    }

    private func cardSpacing(forItem item: Int) -> ConversationCardSpacing {
      ConversationTimelineLayoutHelpers.cardSpacing(for: item, rows: currentRows) { [messagesByID] messageID in
        messagesByID[messageID]
      }
    }

    private func cardSpacingHeightExtra(forItem item: Int) -> CGFloat {
      cardSpacing(forItem: item).heightExtra
    }

    func applyCardPosition(to cell: UICollectionViewCell, at indexPath: IndexPath) {
      let spacing = cardSpacing(forItem: indexPath.item)
      let position = cardPosition(forItem: indexPath.item)
      switch cell {
        case let c as UIKitRichMessageCell:
          c.configureCardPosition(position, topInset: spacing.topInset, bottomInset: spacing.bottomInset)
        case let c as UIKitCompactToolCell:
          c.configureCardPosition(position, topInset: spacing.topInset, bottomInset: spacing.bottomInset)
        case let c as UIKitExpandedToolCell:
          c.configureCardPosition(position, topInset: spacing.topInset, bottomInset: spacing.bottomInset)
        case let c as UIKitRollupSummaryCell:
          c.configureCardPosition(position, topInset: spacing.topInset, bottomInset: spacing.bottomInset)
        case let c as UIKitLiveProgressCell:
          c.configureCardPosition(position, topInset: spacing.topInset, bottomInset: spacing.bottomInset)
        default:
          break
      }
    }
  }

#endif
