//
//  ConversationCollectionView+macOS.swift
//  OrbitDock
//
//  macOS NSTableView implementation for the conversation timeline.
//

import OSLog
import SwiftUI

#if os(macOS)

  import AppKit

  struct ConversationCollectionView: NSViewControllerRepresentable {
    let messages: [TranscriptMessage]
    let chatViewMode: ChatViewMode
    let isSessionActive: Bool
    let workStatus: Session.WorkStatus
    let currentTool: String?
    let pendingToolName: String?
    let pendingToolInput: String?
    let provider: Provider
    let model: String?
    let sessionId: String?
    let serverState: ServerAppState
    let hasMoreMessages: Bool
    let currentPrompt: String?
    let messageCount: Int
    let remainingLoadCount: Int
    let openFileInReview: ((String) -> Void)?
    let onLoadMore: () -> Void
    let onNavigateToReviewFile: ((String, Int) -> Void)?

    @Binding var isPinned: Bool
    @Binding var unreadCount: Int
    @Binding var scrollToBottomTrigger: Int

    func makeCoordinator() -> Coordinator {
      Coordinator(parent: self)
    }

    func makeNSViewController(context: Context) -> ConversationCollectionViewController {
      let vc = ConversationCollectionViewController()
      vc.coordinator = context.coordinator
      vc.serverState = serverState
      vc.openFileInReview = openFileInReview
      vc.provider = provider
      vc.model = model
      vc.sessionId = sessionId
      vc.onLoadMore = onLoadMore
      vc.onNavigateToReviewFile = onNavigateToReviewFile
      vc.isPinnedToBottom = isPinned

      vc.applyFullState(
        messages: messages,
        chatViewMode: chatViewMode,
        isSessionActive: isSessionActive,
        workStatus: workStatus,
        currentTool: currentTool,
        pendingToolName: pendingToolName,
        pendingToolInput: pendingToolInput,
        currentPrompt: currentPrompt,
        messageCount: messageCount,
        remainingLoadCount: remainingLoadCount,
        hasMoreMessages: hasMoreMessages
      )
      return vc
    }

    func updateNSViewController(_ vc: ConversationCollectionViewController, context: Context) {
      vc.coordinator = context.coordinator
      vc.serverState = serverState
      vc.openFileInReview = openFileInReview
      vc.provider = provider
      vc.model = model
      vc.sessionId = sessionId
      vc.onLoadMore = onLoadMore
      vc.onNavigateToReviewFile = onNavigateToReviewFile

      let oldMode = vc.sourceState.metadata.chatViewMode
      let oldMessageCount = vc.sourceState.messages.count

      vc.applyFullState(
        messages: messages,
        chatViewMode: chatViewMode,
        isSessionActive: isSessionActive,
        workStatus: workStatus,
        currentTool: currentTool,
        pendingToolName: pendingToolName,
        pendingToolInput: pendingToolInput,
        currentPrompt: currentPrompt,
        messageCount: messageCount,
        remainingLoadCount: remainingLoadCount,
        hasMoreMessages: hasMoreMessages
      )

      // Defer snapshot work to avoid "modifying state during view update"
      let modeChanged = oldMode != chatViewMode
      let msgCount = messages.count
      let needsScroll = context.coordinator.lastScrollToBottomTrigger != scrollToBottomTrigger
      if needsScroll {
        context.coordinator.lastScrollToBottomTrigger = scrollToBottomTrigger
      }
      Task { @MainActor in
        if modeChanged {
          vc.rebuildSnapshot(animated: false)
        } else {
          vc.applyProjectionUpdate()
        }

        // Unread count tracking
        if !vc.isPinnedToBottom, msgCount > oldMessageCount {
          context.coordinator.unreadDelta(msgCount - oldMessageCount)
        }

        if needsScroll {
          vc.isPinnedToBottom = true
          vc.scrollToBottom(animated: true)
        }
      }
    }

    class Coordinator {
      var parent: ConversationCollectionView
      var lastScrollToBottomTrigger: Int

      init(parent: ConversationCollectionView) {
        self.parent = parent
        lastScrollToBottomTrigger = parent.scrollToBottomTrigger
      }

      func pinnedChanged(_ pinned: Bool) {
        parent.isPinned = pinned
      }

      func unreadDelta(_ delta: Int) {
        parent.unreadCount += delta
      }

      func unreadReset() {
        parent.unreadCount = 0
      }
    }
  }

  // MARK: - macOS ViewController (NSTableView + explicit sizing)

  class ConversationCollectionViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var coordinator: ConversationCollectionView.Coordinator?
    var serverState: ServerAppState?
    var openFileInReview: ((String) -> Void)?
    var provider: Provider = .claude
    var model: String?
    var sessionId: String?
    var onLoadMore: (() -> Void)?
    var onNavigateToReviewFile: ((String, Int) -> Void)?
    var isPinnedToBottom = true

    // Derived caches for O(1) cell rendering lookups
    private var messagesByID: [String: TranscriptMessage] = [:]
    private var messageMeta: [String: ConversationView.MessageMeta] = [:]
    private var turnsByID: [String: TurnSummary] = [:]

    private var programmaticScrollInProgress = false
    private var pendingPinnedScroll = false
    private var isNormalizingHorizontalOffset = false
    private var isLoadingMoreAtTop = false
    private var loadMoreBaselineMessageCount = 0
    private var lastKnownWidth: CGFloat = 0

    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var tableColumn: NSTableColumn!
    var sourceState = ConversationSourceState()
    var uiState = ConversationUIState()
    private var projectionResult = ProjectionResult.empty
    private var currentRows: [TimelineRow] = []
    private var rowIndexByTimelineRowID: [TimelineRowID: Int] = [:]
    private let heightEngine = ConversationHeightEngine()
    private let signposter = OSSignposter(
      subsystem: Bundle.main.bundleIdentifier ?? "OrbitDock",
      category: "conversation-timeline"
    )
    private let logger = TimelineFileLogger.shared
    private var pendingLayoutInvalidationRowIDs: Set<TimelineRowID> = []
    private var pendingIntrinsicHeightsByRowID: [TimelineRowID: CGFloat] = [:]
    private var hasPendingLayoutInvalidationFlush = false
    private var shouldRepinAfterLayoutInvalidation = false
    private let sizingCell = HostingTableCellView(frame: .zero)
    private let nativeSizingCell = NativeMessageTableCellView(frame: .zero)
    private let richSizingCell = NativeRichMessageCellView(frame: .zero)
    private var lastMeasuredRowContent: (rowID: TimelineRowID, content: AnyView)?
    private var needsInitialScroll = true
    /// Tracks which thinking message IDs have been expanded by the user.
    private var expandedThinkingIDs: Set<String> = []

    override func loadView() {
      view = NSView()
      view.wantsLayer = true
      view.layer?.backgroundColor = ConversationLayout.backgroundPrimary.cgColor
    }

    override func viewDidLoad() {
      super.viewDidLoad()
      setupScrollView()
      setupTableView()
      setupScrollObservers()
      rebuildSnapshot(animated: false)
    }

    override func viewDidLayout() {
      super.viewDidLayout()
      updateTableColumnWidth()
      clampHorizontalOffsetIfNeeded()

      let width = availableRowWidth
      if abs(width - lastKnownWidth) > 0.5 {
        lastKnownWidth = width
        ConversationTimelineReducer.reduce(source: &sourceState, ui: &uiState, action: .widthChanged(width))
        heightEngine.invalidateAll()
        if !currentRows.isEmpty {
          tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0 ..< currentRows.count))
        }
      }

      if needsInitialScroll, !sourceState.messages.isEmpty {
        needsInitialScroll = false
        scrollToBottom(animated: false)
      }
    }

    private var availableRowWidth: CGFloat {
      max(1, scrollView?.contentView.bounds.width ?? view.bounds.width)
    }

    private func setupScrollView() {
      scrollView = NSScrollView()
      scrollView.translatesAutoresizingMaskIntoConstraints = false
      scrollView.hasVerticalScroller = true
      scrollView.hasHorizontalScroller = false
      scrollView.horizontalScrollElasticity = .none
      scrollView.autohidesScrollers = true
      scrollView.drawsBackground = true
      scrollView.backgroundColor = ConversationLayout.backgroundPrimary
      scrollView.scrollerStyle = .overlay

      let clipView = VerticalOnlyClipView()
      clipView.postsBoundsChangedNotifications = true
      clipView.drawsBackground = true
      clipView.backgroundColor = ConversationLayout.backgroundPrimary
      scrollView.contentView = clipView

      view.addSubview(scrollView)
      NSLayoutConstraint.activate([
        // 1pt top margin works around a macOS Tahoe clipping regression where rows
        // bleed into the header area when the scroll view spans the full parent height.
        scrollView.topAnchor.constraint(equalTo: view.topAnchor, constant: 1),
        scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      ])
    }

    private func setupTableView() {
      tableView = WidthClampedTableView(frame: .zero)
      tableView.delegate = self
      tableView.dataSource = self
      tableView.headerView = nil
      tableView.backgroundColor = ConversationLayout.backgroundPrimary
      tableView.usesAlternatingRowBackgroundColors = false
      tableView.selectionHighlightStyle = .none
      tableView.intercellSpacing = .zero
      tableView.gridStyleMask = []
      tableView.focusRingType = .none
      tableView.clipsToBounds = true
      // .plain removes the default cell-view insets that .automatic/.inset adds.
      // Without this, NSTableView offsets cells by ~16pt from the row's leading edge,
      // pushing content past the right boundary.
      tableView.style = .plain
      tableView.allowsColumnResizing = false
      tableView.allowsColumnReordering = false
      tableView.allowsColumnSelection = false
      tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
      tableView.rowHeight = 44

      tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("conversation-main-column"))
      tableColumn.isEditable = false
      tableColumn.resizingMask = .autoresizingMask
      tableColumn.minWidth = 1
      tableView.addTableColumn(tableColumn)

      tableView.frame = scrollView.bounds
      tableView.autoresizingMask = [.width]
      scrollView.documentView = tableView
      updateTableColumnWidth()
    }

    private func updateTableColumnWidth() {
      let width = availableRowWidth
      if abs(tableColumn.width - width) > 0.5 {
        tableColumn.width = width
      }
    }

    // MARK: - Scroll Observation

    private func setupScrollObservers() {
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

    private func enqueueLayoutInvalidation(
      for rowID: TimelineRowID,
      intrinsicHeight: CGFloat?,
      keepPinnedAnchor: Bool
    ) {
      if let intrinsicHeight {
        pendingIntrinsicHeightsByRowID[rowID] = intrinsicHeight
      }
      pendingLayoutInvalidationRowIDs.insert(rowID)
      if keepPinnedAnchor, isPinnedToBottom {
        shouldRepinAfterLayoutInvalidation = true
      }
      guard !hasPendingLayoutInvalidationFlush else { return }

      hasPendingLayoutInvalidationFlush = true
      DispatchQueue.main.async { [weak self] in
        self?.flushPendingLayoutInvalidation()
      }
    }

    private func flushPendingLayoutInvalidation() {
      hasPendingLayoutInvalidationFlush = false
      let shouldRepin = shouldRepinAfterLayoutInvalidation
      shouldRepinAfterLayoutInvalidation = false

      guard !pendingLayoutInvalidationRowIDs.isEmpty else { return }

      let rowIDs = pendingLayoutInvalidationRowIDs
      pendingLayoutInvalidationRowIDs.removeAll()

      var validRows = IndexSet()
      for rowID in rowIDs {
        defer { pendingIntrinsicHeightsByRowID.removeValue(forKey: rowID) }
        guard let row = rowIndexByTimelineRowID[rowID], row >= 0, row < currentRows.count else {
          heightEngine.invalidate(rowID: rowID)
          continue
        }
        if let intrinsicHeight = pendingIntrinsicHeightsByRowID[rowID], intrinsicHeight > 1 {
          if let key = heightCacheKey(forRow: row) {
            let accepted = heightEngine.storeCorrection(max(1, ceil(intrinsicHeight)), for: key)
            if !accepted {
              logger
                .debug(
                  "  correction REJECTED (already corrected) row \(rowID.rawValue) intrinsic=\(String(format: "%.1f", intrinsicHeight))"
                )
              continue
            }
          }
        } else {
          heightEngine.invalidate(rowID: rowID)
        }
        validRows.insert(row)
      }

      guard !validRows.isEmpty else { return }
      noteHeightChangesWithScrollCompensation(rows: validRows)

      if shouldRepin {
        requestPinnedScroll()
      }
    }

    private func noteHeightChangesWithScrollCompensation(rows: IndexSet) {
      guard !rows.isEmpty else { return }

      // Skip compensation when pinned — pin-scroll handles it
      guard !isPinnedToBottom else {
        tableView.noteHeightOfRows(withIndexesChanged: rows)
        return
      }

      let viewportTopY = scrollView.contentView.bounds.origin.y

      // Sum current heights of rows fully above viewport
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

    private func clampHorizontalOffsetIfNeeded() {
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

    // MARK: - State Updates

    func applyFullState(
      messages: [TranscriptMessage],
      chatViewMode: ChatViewMode,
      isSessionActive: Bool,
      workStatus: Session.WorkStatus,
      currentTool: String?,
      pendingToolName: String?,
      pendingToolInput: String?,
      currentPrompt: String?,
      messageCount: Int,
      remainingLoadCount: Int,
      hasMoreMessages: Bool
    ) {
      let previousMode = sourceState.metadata.chatViewMode
      let identityChanged = messageIdentityChanged(sourceState.messages, messages)

      let metadata = ConversationSourceState.SessionMetadata(
        chatViewMode: chatViewMode,
        isSessionActive: isSessionActive,
        workStatus: workStatus,
        currentTool: currentTool,
        pendingToolName: pendingToolName,
        pendingToolInput: pendingToolInput,
        currentPrompt: currentPrompt,
        messageCount: messageCount,
        remainingLoadCount: remainingLoadCount,
        hasMoreMessages: hasMoreMessages
      )
      ConversationTimelineReducer.reduce(source: &sourceState, ui: &uiState, action: .setSessionMetadata(metadata))
      ConversationTimelineReducer.reduce(source: &sourceState, ui: &uiState, action: .setMessages(messages))

      // Rebuild derived caches
      messagesByID = Dictionary(uniqueKeysWithValues: sourceState.messages.map { ($0.id, $0) })
      if identityChanged || previousMode != chatViewMode || messageMeta.isEmpty {
        messageMeta = ConversationView.computeMessageMetadata(sourceState.messages)
      }

      if isLoadingMoreAtTop {
        if sourceState.messages.count > loadMoreBaselineMessageCount || !hasMoreMessages {
          isLoadingMoreAtTop = false
        }
      }

      rebuildTurns()
      ConversationTimelineReducer.reduce(
        source: &sourceState,
        ui: &uiState,
        action: .setPinnedToBottom(isPinnedToBottom)
      )
    }

    func rebuildSnapshot(animated: Bool = false) {
      lastMeasuredRowContent = nil
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
      lastMeasuredRowContent = nil
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
        // Skip invalidation if the current cache key already matches this row's
        // layoutHash — the height hasn't structurally changed, so re-measuring
        // via the sizing cell would just produce an oscillating value.
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

    private func heightCacheKey(forRow row: Int) -> HeightCacheKey? {
      guard row >= 0, row < currentRows.count else { return nil }
      let timelineRow = currentRows[row]
      return HeightCacheKey(
        rowID: timelineRow.id,
        widthBucket: uiState.widthBucket,
        layoutHash: timelineRow.layoutHash
      )
    }

    private func isPrependTransition(from oldRows: [TimelineRow], to newRows: [TimelineRow]) -> Bool {
      ConversationScrollAnchorMath.isPrependTransition(from: oldRows.map(\.id), to: newRows.map(\.id))
    }

    private func captureTopVisibleAnchor(rows: [TimelineRow]) -> ConversationUIState.ScrollAnchor? {
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

    private func restoreScrollAnchorFromState() {
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

    private func messageIdentityChanged(_ old: [TranscriptMessage], _ new: [TranscriptMessage]) -> Bool {
      guard old.count == new.count else { return true }
      for (lhs, rhs) in zip(old, new) where lhs.id != rhs.id {
        return true
      }
      return false
    }

    private func nativeMessageRow(for row: TimelineRow) -> NativeMessageRowModel? {
      guard case let .message(id) = row.payload else { return nil }
      guard sourceState.metadata.chatViewMode == .verbose else { return nil }
      guard let message = messagesByID[id] else { return nil }
      guard !message.isTool, !message.hasImage else { return nil }
      guard !message.content.isEmpty else { return nil }

      // Keep structurally complex markdown on the SwiftUI renderer.
      // Inline code (single `) and simple bullet lists (` * `) are handled natively
      // with attributed strings — this covers the majority of assistant messages.
      let hasRichMarkdownMarkers = message.content.contains("```")
        || message.content.contains("# ")
        || message.content.contains("\n#")
        || message.content.contains("|")
        || message.content.contains("- [")
      guard !hasRichMarkdownMarkers else { return nil }

      if message.isUser {
        return NativeMessageRowModel(
          speaker: "YOU",
          body: message.content,
          speakerColor: NSColor(calibratedRed: 0.47, green: 0.72, blue: 1.0, alpha: 1),
          textColor: NSColor(calibratedWhite: 0.95, alpha: 1),
          bubbleColor: NSColor(calibratedRed: 0.12, green: 0.18, blue: 0.28, alpha: 0.72)
        )
      }

      if message.isThinking {
        return NativeMessageRowModel(
          speaker: "REASONING",
          body: message.content,
          speakerColor: NSColor(calibratedRed: 0.73, green: 0.68, blue: 0.9, alpha: 1),
          textColor: NSColor(calibratedWhite: 0.82, alpha: 1),
          bubbleColor: NSColor(calibratedRed: 0.17, green: 0.15, blue: 0.23, alpha: 0.7)
        )
      }

      if message.isSteer {
        return NativeMessageRowModel(
          speaker: "STEER",
          body: message.content,
          speakerColor: NSColor(calibratedRed: 0.6, green: 0.8, blue: 1.0, alpha: 1),
          textColor: NSColor(calibratedWhite: 0.9, alpha: 1),
          bubbleColor: NSColor(calibratedRed: 0.14, green: 0.18, blue: 0.22, alpha: 0.7)
        )
      }

      if message.isShell {
        return NativeMessageRowModel(
          speaker: "SHELL",
          body: message.content,
          speakerColor: NSColor(calibratedRed: 0.62, green: 0.9, blue: 0.62, alpha: 1),
          textColor: NSColor(calibratedWhite: 0.92, alpha: 1),
          bubbleColor: NSColor(calibratedRed: 0.13, green: 0.2, blue: 0.13, alpha: 0.72)
        )
      }

      return NativeMessageRowModel(
        speaker: "ASSISTANT",
        body: message.content,
        speakerColor: NSColor(calibratedWhite: 0.78, alpha: 1),
        textColor: NSColor(calibratedWhite: 0.94, alpha: 1),
        bubbleColor: NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.13, alpha: 0.72)
      )
    }

    /// Build a NativeRichMessageRowModel for ANY .message row — no markdown filter.
    /// Returns nil only for tool rows or empty content.
    private func nativeRichMessageRow(for row: TimelineRow) -> NativeRichMessageRowModel? {
      guard case let .message(id) = row.payload else { return nil }
      guard let message = messagesByID[id] else { return nil }
      return SharedModelBuilders.richMessageModel(
        from: message,
        messageID: id,
        isThinkingExpanded: expandedThinkingIDs.contains(id)
      )
    }

    // MARK: - Thinking Expansion

    private func toggleThinkingExpansion(messageID: String, row: Int) {
      if expandedThinkingIDs.contains(messageID) {
        expandedThinkingIDs.remove(messageID)
      } else {
        expandedThinkingIDs.insert(messageID)
      }

      guard row < currentRows.count else { return }
      let rowID = currentRows[row].id
      heightEngine.invalidate(rowID: rowID)

      // Recalculate height and reconfigure the cell
      NSAnimationContext.runAnimationGroup { context in
        context.allowsImplicitAnimation = true
        context.duration = 0.2
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
      }

      // Reconfigure the cell with updated model
      if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
        as? NativeRichMessageCellView,
        let timelineRow = row < currentRows.count ? currentRows[row] : nil,
        let model = nativeRichMessageRow(for: timelineRow)
      {
        let width = max(100, tableView.bounds.width)
        cell.configure(model: model, width: width)
      }
    }

    // MARK: - Compact Tool Row Model Builder

    private func nativeCompactToolRow(for row: TimelineRow) -> NativeCompactToolRowModel? {
      guard case let .tool(id) = row.payload else { return nil }
      guard !uiState.expandedToolCards.contains(id) else { return nil }
      guard let message = messagesByID[id] else { return nil }
      return SharedModelBuilders.compactToolModel(from: message)
    }

    // MARK: - Expanded Tool Model Builder

    private func nativeExpandedToolModel(for row: TimelineRow) -> NativeExpandedToolModel? {
      guard case let .tool(id) = row.payload else { return nil }
      guard uiState.expandedToolCards.contains(id) else { return nil }
      guard let message = messagesByID[id] else { return nil }
      return SharedModelBuilders.expandedToolModel(from: message, messageID: id)
    }

    // MARK: - NSTableViewDataSource / NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int {
      currentRows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
      guard row >= 0, row < currentRows.count else { return nil }
      let timelineRow = currentRows[row]
      let width = availableRowWidth

      // ── Native structural rows ──

      switch timelineRow.kind {
        case .bottomSpacer:
          let id = NativeSpacerCellView.reuseIdentifier
          let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NativeSpacerCellView)
            ?? NativeSpacerCellView(frame: .zero)
          cell.identifier = id
          return cell

        case .turnHeader:
          if case let .turnHeader(turnID) = timelineRow.payload, let turn = turnsByID[turnID] {
            let id = NativeTurnHeaderCellView.reuseIdentifier
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NativeTurnHeaderCellView)
              ?? NativeTurnHeaderCellView(frame: .zero)
            cell.identifier = id
            cell.configure(turn: turn)
            return cell
          }

        case .rollupSummary:
          if case let .rollupSummary(rollupID, hiddenCount, totalToolCount, isExpanded, breakdown) =
            timelineRow.payload
          {
            let id = NativeRollupSummaryCellView.reuseIdentifier
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NativeRollupSummaryCellView)
              ?? NativeRollupSummaryCellView(frame: .zero)
            cell.identifier = id
            cell.configure(
              hiddenCount: hiddenCount, totalToolCount: totalToolCount,
              isExpanded: isExpanded, breakdown: breakdown
            )
            cell.onToggle = { [weak self] in self?.toggleRollup(id: rollupID) }
            return cell
          }

        case .loadMore:
          let id = NativeLoadMoreCellView.reuseIdentifier
          let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NativeLoadMoreCellView)
            ?? NativeLoadMoreCellView(frame: .zero)
          cell.identifier = id
          cell.configure(remainingCount: sourceState.metadata.remainingLoadCount)
          cell.onLoadMore = onLoadMore
          return cell

        case .messageCount:
          let id = NativeMessageCountCellView.reuseIdentifier
          let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NativeMessageCountCellView)
            ?? NativeMessageCountCellView(frame: .zero)
          cell.identifier = id
          cell.configure(displayedCount: sourceState.messages.count, totalCount: sourceState.metadata.messageCount)
          return cell

        case .tool:
          if let toolModel = nativeCompactToolRow(for: timelineRow) {
            let id = NativeCompactToolCellView.reuseIdentifier
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NativeCompactToolCellView)
              ?? NativeCompactToolCellView(frame: .zero)
            cell.identifier = id
            cell.configure(model: toolModel)
            if case let .tool(messageID) = timelineRow.payload {
              cell.onTap = { [weak self] in
                self?.setToolRowExpansion(messageID: messageID, expanded: true)
              }
            }
            return cell
          }

        default:
          break
      }

      // ── Native rich message rows (ALL markdown, zero SwiftUI) ──

      if let richModel = nativeRichMessageRow(for: timelineRow) {
        let richID = NativeRichMessageCellView.reuseIdentifier
        let richCell = (tableView.makeView(withIdentifier: richID, owner: self) as? NativeRichMessageCellView)
          ?? NativeRichMessageCellView(frame: .zero)
        richCell.identifier = richID
        richCell.onThinkingExpandToggle = { [weak self] messageID in
          self?.toggleThinkingExpansion(messageID: messageID, row: row)
        }
        richCell.configure(model: richModel, width: width)
        logger.debug("viewFor[\(row)] \(timelineRow.id.rawValue) native-rich w=\(String(format: "%.0f", width))")
        return richCell
      }

      // ── Native expanded tool cards (ALL tool types, zero SwiftUI) ──

      if let expandedModel = nativeExpandedToolModel(for: timelineRow) {
        let expandedID = NativeExpandedToolCellView.reuseIdentifier
        let expandedCell = (tableView.makeView(withIdentifier: expandedID, owner: self) as? NativeExpandedToolCellView)
          ?? NativeExpandedToolCellView(frame: .zero)
        expandedCell.identifier = expandedID
        expandedCell.onCollapse = { [weak self] messageID in
          self?.setToolRowExpansion(messageID: messageID, expanded: false)
        }
        expandedCell.configure(model: expandedModel, width: width)
        logger
          .debug("viewFor[\(row)] \(timelineRow.id.rawValue) native-expanded-tool w=\(String(format: "%.0f", width))")
        return expandedCell
      }

      // ── Legacy plain text native rows (fallback for verbose mode plain text) ──

      if let nativeModel = nativeMessageRow(for: timelineRow) {
        let nativeID = NativeMessageTableCellView.reuseIdentifier
        let nativeCell = (tableView.makeView(withIdentifier: nativeID, owner: self) as? NativeMessageTableCellView)
          ?? NativeMessageTableCellView(frame: .zero)
        nativeCell.identifier = nativeID
        nativeCell.configure(model: nativeModel)
        logger.debug("viewFor[\(row)] \(timelineRow.id.rawValue) native-message w=\(String(format: "%.0f", width))")
        return nativeCell
      }

      // ── SwiftUI fallback (images, live indicator) ──

      let identifier = HostingTableCellView.reuseIdentifier
      let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? HostingTableCellView)
        ?? HostingTableCellView(frame: .zero)
      cell.identifier = identifier
      let rowID = timelineRow.id
      cell.onContentHeightDidChange = { [weak self] intrinsicHeight in
        guard let self else { return }
        self.logger
          .debug("  correction row[\(row)] \(rowID.rawValue) intrinsic=\(String(format: "%.1f", intrinsicHeight))")
        self.enqueueLayoutInvalidation(for: rowID, intrinsicHeight: intrinsicHeight, keepPinnedAnchor: true)
      }
      let content: AnyView
      if let cached = lastMeasuredRowContent, cached.rowID == timelineRow.id {
        content = cached.content
        lastMeasuredRowContent = nil
      } else {
        content = AnyView(rowContent(for: timelineRow).id(timelineRow.id.rawValue))
      }
      cell.configure(with: content, maxWidth: width)
      logger.debug("viewFor[\(row)] \(timelineRow.id.rawValue) swiftui w=\(String(format: "%.0f", width))")
      return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
      let identifier = NSUserInterfaceItemIdentifier("conversationClearRowView")
      let rowView = (tableView.makeView(withIdentifier: identifier, owner: self) as? ClearTableRowView)
        ?? ClearTableRowView(frame: .zero)
      rowView.identifier = identifier
      return rowView
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
      guard row >= 0, row < currentRows.count else { return 1 }
      let timelineRow = currentRows[row]
      let width = availableRowWidth

      // ── Tier 1: Fixed-height rows (no measurement, no cache, no SwiftUI) ──
      switch timelineRow.kind {
        case .bottomSpacer:
          logger
            .debug("heightOfRow[\(row)] \(timelineRow.id.rawValue) T1-fixed h=\(ConversationLayout.bottomSpacerHeight)")
          return ConversationLayout.bottomSpacerHeight
        case .turnHeader:
          logger
            .debug("heightOfRow[\(row)] \(timelineRow.id.rawValue) T1-fixed h=\(ConversationLayout.turnHeaderHeight)")
          return ConversationLayout.turnHeaderHeight
        case .loadMore:
          return ConversationLayout.loadMoreHeight
        case .messageCount:
          return ConversationLayout.messageCountHeight
        case .rollupSummary:
          return ConversationLayout.rollupSummaryHeight
        case .tool:
          if case let .tool(id) = timelineRow.payload, !uiState.expandedToolCards.contains(id) {
            let compactH: CGFloat
            if let message = messagesByID[id] {
              let summary = CompactToolHelpers.summary(for: message)
              compactH = NativeCompactToolCellView.requiredHeight(for: tableView.bounds.width, summary: summary)
            } else {
              compactH = ConversationLayout.compactToolRowHeight
            }
            logger
              .debug(
                "heightOfRow[\(row)] \(timelineRow.id.rawValue) T1-compactTool h=\(compactH)"
              )
            return compactH
          }
        default: break
      }

      // ── Tier 2+3: Measured rows (native text or SwiftUI fallback) ──
      guard let cacheKey = heightCacheKey(forRow: row) else { return 1 }
      if let cachedHeight = heightEngine.height(for: cacheKey) {
        signposter.emitEvent("timeline-height-cache-hit")
        logger
          .debug("heightOfRow[\(row)] \(timelineRow.id.rawValue) cache-hit h=\(String(format: "%.1f", cachedHeight))")
        return cachedHeight
      }
      signposter.emitEvent("timeline-height-cache-miss")
      logger.info("heightOfRow[\(row)] \(timelineRow.id.rawValue) cache-miss w=\(String(format: "%.0f", width))")

      // Tier 2a: Native rich message rows (ALL markdown + images, zero SwiftUI)
      if let richModel = nativeRichMessageRow(for: timelineRow) {
        let measuredHeight = max(1, ceil(NativeRichMessageCellView.requiredHeight(for: width, model: richModel)))
        heightEngine.store(measuredHeight, for: cacheKey)
        logger.debug("heightOfRow[\(row)] T2-rich h=\(String(format: "%.1f", measuredHeight))")
        return measuredHeight
      }

      // Tier 2b: Native expanded tool cards (deterministic line-count-based)
      if let expandedModel = nativeExpandedToolModel(for: timelineRow) {
        let measuredHeight = max(1, ceil(NativeExpandedToolCellView.requiredHeight(for: width, model: expandedModel)))
        heightEngine.store(measuredHeight, for: cacheKey)
        logger.debug("heightOfRow[\(row)] T2-expandedTool h=\(String(format: "%.1f", measuredHeight))")
        return measuredHeight
      }

      // Tier 2c: Legacy plain text native rows
      if let nativeModel = nativeMessageRow(for: timelineRow) {
        let measuredHeight = max(1, ceil(nativeSizingCell.requiredHeight(for: width, model: nativeModel)))
        heightEngine.store(measuredHeight, for: cacheKey)
        logger.debug("heightOfRow[\(row)] T2-native h=\(String(format: "%.1f", measuredHeight))")
        return measuredHeight
      }

      // Tier 3: SwiftUI fallback (images, live indicator)
      let content = AnyView(rowContent(for: timelineRow).id(timelineRow.id.rawValue))
      lastMeasuredRowContent = (rowID: timelineRow.id, content: content)
      sizingCell.configure(with: content, maxWidth: width)
      let measuredHeight = max(1, ceil(sizingCell.requiredHeight(for: width)))
      heightEngine.store(measuredHeight, for: cacheKey)
      sizingCell.clearContent()
      logger.debug("heightOfRow[\(row)] T3-swiftui h=\(String(format: "%.1f", measuredHeight))")
      return measuredHeight
    }

    /// SwiftUI content for Tier 3 rows only.
    /// Structural rows (loadMore, messageCount, turnHeader, rollupSummary, bottomSpacer)
    /// and compact tool rows are rendered natively and never reach this path.
    private func rowContent(for row: TimelineRow) -> AnyView {
      switch row.kind {
        case .message, .tool:
          guard let messageID = timelineMessageID(for: row) else {
            return AnyView(Color.clear.frame(height: 1))
          }
          return messageContent(row: row, messageID: messageID)

        case .liveIndicator:
          let meta = sourceState.metadata
          return AnyView(
            WorkStreamLiveIndicator(
              workStatus: meta.workStatus,
              currentTool: meta.currentTool,
              currentPrompt: meta.currentPrompt,
              pendingToolName: meta.pendingToolName,
              pendingToolInput: meta.pendingToolInput,
              provider: provider
            )
          )

        // Native rows — should never reach SwiftUI, but provide minimal fallback
        case .loadMore, .messageCount, .turnHeader, .rollupSummary, .bottomSpacer:
          return AnyView(Color.clear.frame(height: 1))
      }
    }

    private func timelineMessageID(for row: TimelineRow) -> String? {
      switch row.payload {
        case let .message(id):
          id
        case let .tool(id):
          id
        default:
          nil
      }
    }

    private func messageContent(row: TimelineRow, messageID: String) -> AnyView {
      guard let message = messagesByID[messageID] else {
        return AnyView(Color.clear.frame(height: 1))
      }

      let meta = messageMeta[messageID]
      let turnsAfter = meta?.turnsAfter
      let nthUser = meta?.nthUserMessage
      let serverState = self.serverState
      let sid = self.sessionId
      let provider = self.provider
      let model = self.model
      let onNavigateToReviewFile = self.onNavigateToReviewFile
      let openFileInReview = self.openFileInReview
      let isToolRow = row.kind == .tool
      let toolExpanded = isToolRow ? uiState.expandedToolCards.contains(messageID) : nil
      let onExpandedChange: ((Bool) -> Void)? = isToolRow ? { [weak self] expanded in
        self?.setToolRowExpansion(messageID: messageID, expanded: expanded)
      } : nil

      let content = WorkStreamEntry(
        message: message,
        provider: provider,
        model: model,
        sessionId: sid,
        rollbackTurns: turnsAfter,
        nthUserMessage: nthUser,
        onRollback: turnsAfter != nil ? {
          if let sid, let turns = turnsAfter {
            serverState?.rollbackTurns(sessionId: sid, numTurns: UInt32(turns))
          }
        } : nil,
        onFork: nthUser != nil ? {
          if let sid, let nth = nthUser {
            serverState?.forkSession(sessionId: sid, nthUserMessage: UInt32(nth))
          }
        } : nil,
        onNavigateToReviewFile: onNavigateToReviewFile,
        externallyExpanded: toolExpanded,
        onExpandedChange: onExpandedChange
      )
      .environment(\.openFileInReview, openFileInReview)

      if let serverState {
        return AnyView(content.environment(serverState))
      } else {
        return AnyView(content)
      }
    }

    private func setToolRowExpansion(messageID: String, expanded: Bool) {
      let isExpanded = uiState.expandedToolCards.contains(messageID)
      guard isExpanded != expanded else { return }
      ConversationTimelineReducer.reduce(source: &sourceState, ui: &uiState, action: .toggleToolCard(messageID))
      applyProjectionUpdate(preserveAnchor: true)
    }

    private func toggleRollup(id: String) {
      ConversationTimelineReducer.reduce(source: &sourceState, ui: &uiState, action: .toggleRollup(id))
      applyProjectionUpdate(preserveAnchor: true)
    }

    // MARK: - Scroll

    private func requestPinnedScroll() {
      guard isPinnedToBottom else { return }
      guard !pendingPinnedScroll else { return }
      pendingPinnedScroll = true
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.scrollToBottom(animated: false)
        self.pendingPinnedScroll = false
      }
    }

    func scrollToBottom(animated: Bool) {
      guard tableView.numberOfRows > 0 else { return }
      let targetY = max(0, tableView.bounds.height - scrollView.contentView.bounds.height)

      programmaticScrollInProgress = true
      if animated {
        NSAnimationContext.runAnimationGroup { context in
          context.duration = 0.18
          self.scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: targetY))
        } completionHandler: { [weak self] in
          guard let self else { return }
          self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
          self.programmaticScrollInProgress = false
        }
      } else {
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        programmaticScrollInProgress = false
      }
    }

    deinit {
      NotificationCenter.default.removeObserver(self)
    }
  }

#endif
