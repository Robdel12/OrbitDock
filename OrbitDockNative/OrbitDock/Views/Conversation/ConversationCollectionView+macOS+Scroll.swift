#if os(macOS)

  import AppKit
  import os

  extension ConversationCollectionViewController {
    func setupScrollObservers() {
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(scrollWillStartLiveScroll(_:)),
        name: NSScrollView.willStartLiveScrollNotification,
        object: scrollView
      )
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(scrollDidEndLiveScroll(_:)),
        name: NSScrollView.didEndLiveScrollNotification,
        object: scrollView
      )
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(scrollBoundsDidChange(_:)),
        name: NSView.boundsDidChangeNotification,
        object: scrollView.contentView
      )
    }

    @objc private func scrollWillStartLiveScroll(_ notification: Notification) {
      guard !programmaticScrollInProgress else { return }
      if isPinnedToBottom {
        isPinnedToBottom = false
        coordinator?.pinnedChanged(false)
        ConversationTimelineReducer.reduce(source: &sourceState, ui: &uiState, action: .setPinnedToBottom(false))
      }
    }

    @objc private func scrollDidEndLiveScroll(_ notification: Notification) {
      checkRepinIfNearBottom()
    }

    @objc private func scrollBoundsDidChange(_ notification: Notification) {
      clampHorizontalOffsetIfNeeded()
      maybeLoadMoreIfNearTop()
      guard !programmaticScrollInProgress else { return }

      if isPinnedToBottom {
        let distance = distanceFromBottom()
        if distance > 80 {
          isPinnedToBottom = false
          coordinator?.pinnedChanged(false)
          ConversationTimelineReducer.reduce(source: &sourceState, ui: &uiState, action: .setPinnedToBottom(false))
        }
      } else {
        checkRepinIfNearBottom()
      }
    }

    func noteHeightChangesWithScrollCompensation(rows: IndexSet) {
      guard !rows.isEmpty else { return }

      guard !isPinnedToBottom else {
        tableView.noteHeightOfRows(withIndexesChanged: rows)
        return
      }

      let viewportTopY = scrollView.contentView.bounds.origin.y

      var oldHeightAbove: CGFloat = 0
      var aboveRows = IndexSet()
      for row in rows {
        let rect = tableView.rect(ofRow: row)
        if rect.maxY <= viewportTopY + 1 {
          oldHeightAbove += rect.height
          aboveRows.insert(row)
        }
      }

      tableView.noteHeightOfRows(withIndexesChanged: rows)

      guard !aboveRows.isEmpty else { return }

      var newHeightAbove: CGFloat = 0
      for row in aboveRows {
        newHeightAbove += tableView.rect(ofRow: row).height
      }

      let delta = newHeightAbove - oldHeightAbove
      guard abs(delta) > 0.5 else { return }

      let newY = max(0, viewportTopY + delta)
      programmaticScrollInProgress = true
      scrollView.contentView.scroll(to: NSPoint(x: 0, y: newY))
      scrollView.reflectScrolledClipView(scrollView.contentView)
      programmaticScrollInProgress = false
    }

    func clampHorizontalOffsetIfNeeded() {
      guard !isNormalizingHorizontalOffset else { return }
      let origin = scrollView.contentView.bounds.origin
      guard abs(origin.x) > 0.5 else { return }

      isNormalizingHorizontalOffset = true
      scrollView.contentView.scroll(to: NSPoint(x: 0, y: origin.y))
      scrollView.reflectScrolledClipView(scrollView.contentView)
      isNormalizingHorizontalOffset = false
    }

    private func distanceFromBottom() -> CGFloat {
      let contentHeight = tableView.bounds.height
      let scrollOffset = scrollView.contentView.bounds.origin.y
      let viewportHeight = scrollView.contentView.bounds.height
      return contentHeight - scrollOffset - viewportHeight
    }

    private func checkRepinIfNearBottom() {
      if distanceFromBottom() < 60 {
        isPinnedToBottom = true
        coordinator?.pinnedChanged(true)
        coordinator?.unreadReset()
        ConversationTimelineReducer.reduce(source: &sourceState, ui: &uiState, action: .setPinnedToBottom(true))
      }
    }

    private func maybeLoadMoreIfNearTop() {
      guard sourceState.metadata.hasMoreMessages else {
        isLoadingMoreAtTop = false
        return
      }
      guard !isLoadingMoreAtTop else { return }
      guard scrollView.contentView.bounds.minY <= 40 else { return }
      guard let onLoadMore else { return }

      isLoadingMoreAtTop = true
      loadMoreBaselineMessageCount = sourceState.messages.count
      onLoadMore()
    }

    func isPrependTransition(from oldRows: [TimelineRow], to newRows: [TimelineRow]) -> Bool {
      ConversationScrollAnchorMath.isPrependTransition(from: oldRows.map(\.id), to: newRows.map(\.id))
    }

    func captureTopVisibleAnchor(rows: [TimelineRow]) -> ConversationUIState.ScrollAnchor? {
      guard !rows.isEmpty else { return nil }
      let visibleRows = tableView.rows(in: scrollView.contentView.bounds)
      guard visibleRows.location != NSNotFound, visibleRows.length > 0 else { return nil }
      let topRow = visibleRows.location
      guard topRow >= 0, topRow < rows.count else { return nil }

      let rowRect = tableView.rect(ofRow: topRow)
      let delta = ConversationScrollAnchorMath.captureDelta(
        viewportTopY: scrollView.contentView.bounds.minY,
        rowTopY: rowRect.minY
      )
      return ConversationUIState.ScrollAnchor(
        rowID: rows[topRow].id,
        deltaFromRowTop: delta
      )
    }

    func restoreScrollAnchorFromState() {
      guard let anchor = uiState.scrollAnchor else { return }
      let restoreState = signposter.beginInterval("timeline-restore-prepend-anchor")
      defer {
        signposter.endInterval("timeline-restore-prepend-anchor", restoreState)
        ConversationTimelineReducer.reduce(source: &sourceState, ui: &uiState, action: .setScrollAnchor(nil))
      }

      guard let row = rowIndexByTimelineRowID[anchor.rowID], row >= 0, row < tableView.numberOfRows else { return }
      let rowRect = tableView.rect(ofRow: row)
      let clampedTargetY = ConversationScrollAnchorMath.restoredViewportTop(
        rowTopY: rowRect.minY,
        deltaFromRowTop: anchor.deltaFromRowTop,
        contentHeight: tableView.bounds.height,
        viewportHeight: scrollView.contentView.bounds.height
      )

      programmaticScrollInProgress = true
      scrollView.contentView.scroll(to: NSPoint(x: 0, y: clampedTargetY))
      scrollView.reflectScrolledClipView(scrollView.contentView)
      programmaticScrollInProgress = false
    }
  }

#endif
