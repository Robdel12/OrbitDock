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

  private func sanitizedConversationMessages(
    _ messages: [TranscriptMessage],
    sessionId: String?,
    source: String
  ) -> [TranscriptMessage] {
    guard !messages.isEmpty else { return messages }

    var seenIDs = Set<String>()
    seenIDs.reserveCapacity(messages.count)

    for message in messages {
      let trimmedID = message.id.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmedID.isEmpty || !seenIDs.insert(trimmedID).inserted {
        return ConversationRenderMessageNormalizer.normalize(messages, sessionId: sessionId, source: source)
      }
    }

    return messages
  }

  struct ConversationCollectionView: NSViewControllerRepresentable {
    let messages: [TranscriptMessage]
    let chatViewMode: ChatViewMode
    let isSessionActive: Bool
    let workStatus: Session.WorkStatus
    let currentTool: String?
    let pendingToolName: String?
    let pendingPermissionDetail: String?
    let provider: Provider
    let model: String?
    let sessionId: String?
    let serverState: SessionStore
    let hasMoreMessages: Bool
    let currentPrompt: String?
    let messageCount: Int
    let remainingLoadCount: Int
    let openFileInReview: ((String) -> Void)?
    let onLoadMore: () -> Void
    let onNavigateToReviewFile: ((String, Int) -> Void)?
    let onOpenPendingApprovalPanel: (() -> Void)?

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
      vc.onOpenPendingApprovalPanel = onOpenPendingApprovalPanel
      vc.isPinnedToBottom = isPinned

      vc.applyFullState(
        messages: messages,
        chatViewMode: chatViewMode,
        isSessionActive: isSessionActive,
        workStatus: workStatus,
        currentTool: currentTool,
        pendingToolName: pendingToolName,
        pendingPermissionDetail: pendingPermissionDetail,
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
      vc.onOpenPendingApprovalPanel = onOpenPendingApprovalPanel

      let oldMode = vc.sourceState.metadata.chatViewMode
      let oldMessageCount = vc.sourceState.messages.count

      vc.applyFullState(
        messages: messages,
        chatViewMode: chatViewMode,
        isSessionActive: isSessionActive,
        workStatus: workStatus,
        currentTool: currentTool,
        pendingToolName: pendingToolName,
        pendingPermissionDetail: pendingPermissionDetail,
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
    var serverState: SessionStore?
    var openFileInReview: ((String) -> Void)?
    var provider: Provider = .claude
    var model: String?
    var sessionId: String?
    var onLoadMore: (() -> Void)?
    var onNavigateToReviewFile: ((String, Int) -> Void)?
    var onOpenPendingApprovalPanel: (() -> Void)?
    var isPinnedToBottom = true

    // Derived caches for O(1) cell rendering lookups
    private var messagesByID: [String: TranscriptMessage] = [:]
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
      UserDefaults.standard.set(false, forKey: "NSTableViewCanEstimateRowHeights")

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

      // Approval metadata is server-authoritative from session summary fields.
      let session = serverState?.sessions.first(where: { $0.id == self.sessionId })
      let resolvedApprovalId = session?.pendingApprovalId
      let approvalMode: ApprovalCardMode = {
        guard let s = session else { return .none }
        return ApprovalCardModeResolver.resolve(
          for: s,
          pendingApprovalId: resolvedApprovalId,
          approvalType: nil
        )
      }()
      let shouldShowApprovalCard = approvalMode != .none

      let metadata = ConversationSourceState.SessionMetadata(
        chatViewMode: chatViewMode,
        isSessionActive: isSessionActive,
        workStatus: workStatus,
        currentTool: session?.lastTool ?? currentTool,
        pendingToolName: session?.pendingToolName ?? pendingToolName,
        pendingApprovalCommand: String.shellCommandDisplay(from: session?.pendingToolInput),
        pendingPermissionDetail: session?.pendingPermissionDetail ?? pendingPermissionDetail,
        currentPrompt: currentPrompt,
        messageCount: messageCount,
        remainingLoadCount: remainingLoadCount,
        hasMoreMessages: hasMoreMessages,
        needsApprovalCard: shouldShowApprovalCard,
        approvalMode: approvalMode,
        pendingQuestion: session?.pendingQuestion,
        pendingApprovalId: resolvedApprovalId,
        isDirectSession: session?.isDirect ?? false,
        isDirectCodexSession: session?.isDirectCodex ?? false,
        supportsRichToolingCards: session?.isDirect ?? false,
        sessionId: self.sessionId,
        projectPath: session?.projectPath
      )
      ConversationTimelineReducer.reduce(source: &sourceState, ui: &uiState, action: .setSessionMetadata(metadata))
      ConversationTimelineReducer.reduce(source: &sourceState, ui: &uiState, action: .setMessages(resolvedMessages))

      // Rebuild derived caches
      messagesByID = Dictionary(uniqueKeysWithValues: sourceState.messages.map { ($0.id, $0) })

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

    private var rowContext: AppKitConversationRowContext {
      AppKitConversationRowContext(
        rows: currentRows,
        messagesByID: messagesByID,
        turnsByID: turnsByID,
        metadata: sourceState.metadata,
        uiState: uiState,
        approvalCardModel: buildApprovalCardModel(),
        expandedThinkingIDs: expandedThinkingIDs,
        rowWidth: availableRowWidth,
        tableWidth: tableView?.bounds.width ?? 0
      )
    }

    private var rowHandlers: AppKitConversationRowHandlers {
      AppKitConversationRowHandlers(
        toggleThinkingExpansion: { [weak self] messageID, row in
          self?.toggleThinkingExpansion(messageID: messageID, row: row)
        },
        expandToolRow: { [weak self] messageID in
          self?.setToolRowExpansion(messageID: messageID, expanded: true)
        },
        collapseToolRow: { [weak self] messageID in
          self?.setToolRowExpansion(messageID: messageID, expanded: false)
        },
        cancelShellCommand: { [weak self] requestID in
          self?.cancelShellCommand(requestID: requestID)
        },
        toggleRollup: { [weak self] rollupID in
          self?.toggleRollup(id: rollupID)
        },
        toggleTurnExpansion: { [weak self] turnID in
          self?.toggleTurnExpansion(turnID: turnID)
        },
        loadMore: onLoadMore,
        openPendingApprovalPanel: onOpenPendingApprovalPanel
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
        let model = rowContext.richMessageModel(for: timelineRow)
      {
        let width = max(100, tableView.bounds.width)
        cell.configure(model: model, width: width)
      }
    }

    // MARK: - Approval Card Model

    private func buildApprovalCardModel() -> ApprovalCardModel? {
      guard let sid = sessionId,
            let serverState,
            let session = serverState.sessions.first(where: { $0.id == sid })
      else { return nil }
      let pendingId = session.pendingApprovalId?.trimmingCharacters(in: .whitespacesAndNewlines)
      let pendingApproval: ServerApprovalRequest? = {
        guard let pendingId, !pendingId.isEmpty else { return nil }
        guard let candidate = serverState.session(sid).pendingApproval else { return nil }
        let candidateId = candidate.id.trimmingCharacters(in: .whitespacesAndNewlines)
        return candidateId == pendingId ? candidate : nil
      }()
      return ApprovalCardModelBuilder.build(
        session: session,
        pendingApproval: pendingApproval,
        approvalHistory: serverState.session(sid).approvalHistory,
        transcriptMessages: serverState.conversation(sid).messages
      )
    }

    // MARK: - NSTableViewDataSource / NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int {
      currentRows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
      AppKitConversationRowFactory.makeView(
        tableView: tableView,
        row: row,
        context: rowContext,
        handlers: rowHandlers,
        logger: logger
      )
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
      AppKitConversationRowFactory.makeRowView(
        tableView: tableView,
        row: row,
        context: rowContext
      )
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
      guard row >= 0, row < currentRows.count else { return 1 }
      let width = availableRowWidth
      let measurementWidth = width > 1
        ? width
        : max(lastKnownWidth, tableColumn.width, tableView.bounds.width, view.bounds.width)

      // During early layout/rebuild passes NSTableView can ask for heights before
      // the clip view has a valid width. Never cache these placeholder values.
      if measurementWidth <= 1 {
        return tableView.rowHeight
      }

      // ── Tier 2: Measured rows (native rich message / expanded tool) ──
      guard let cacheKey = heightCacheKey(forRow: row) else { return 1 }
      if let cachedHeight = heightEngine.height(for: cacheKey) {
        signposter.emitEvent("timeline-height-cache-hit")
        return cachedHeight
      }
      signposter.emitEvent("timeline-height-cache-miss")

      let measuredHeight = AppKitConversationRowFactory.height(
        for: row,
        context: rowContext,
        measurementWidth: measurementWidth
      )
      heightEngine.store(measuredHeight, for: cacheKey)
      return measuredHeight
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

    private func toggleTurnExpansion(turnID: String) {
      ConversationTimelineReducer.reduce(source: &sourceState, ui: &uiState, action: .toggleTurnExpansion(turnID))
      applyProjectionUpdate(preserveAnchor: true)
    }

    private func cancelShellCommand(requestID: String) {
      guard let serverState, let sessionId else { return }
      Task {
        // Route to stopTask for task/subagent cards, cancelShell for bash
        if let msg = messagesByID[requestID], msg.toolName?.lowercased() == "task" {
          try? await serverState.stopTask(sessionId, taskId: requestID)
        } else {
          try? await serverState.cancelShell(sessionId, requestId: requestID)
        }
      }
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
