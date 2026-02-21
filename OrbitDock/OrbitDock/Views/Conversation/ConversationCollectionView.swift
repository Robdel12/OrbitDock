//
//  ConversationCollectionView.swift
//  OrbitDock
//
//  Native scroll container for conversation content.
//  iOS: UICollectionView + native UIKit cells (deterministic heights, no UIHostingConfiguration)
//  macOS: NSScrollView + NSTableView virtualization + explicit dynamic row sizing
//

import OSLog
import SwiftUI

// MARK: - iOS Implementation

#if os(iOS)

  import UIKit

  struct ConversationCollectionView: UIViewControllerRepresentable {
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

    func makeUIViewController(context: Context) -> ConversationCollectionViewController {
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

    func updateUIViewController(_ vc: ConversationCollectionViewController, context: Context) {
      vc.coordinator = context.coordinator
      vc.serverState = serverState
      vc.openFileInReview = openFileInReview
      vc.provider = provider
      vc.model = model
      vc.sessionId = sessionId
      vc.onLoadMore = onLoadMore
      vc.onNavigateToReviewFile = onNavigateToReviewFile

      let oldMode = vc.chatViewMode

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
      // — snapshot application triggers UIKit layout which can read back into SwiftUI bindings.
      let modeChanged = oldMode != chatViewMode
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

  // MARK: - iOS ViewController

  class ConversationCollectionViewController: UIViewController, UICollectionViewDelegate,
    UICollectionViewDelegateFlowLayout,
    UIScrollViewDelegate
  {
    var coordinator: ConversationCollectionView.Coordinator?
    var serverState: ServerAppState?
    var openFileInReview: ((String) -> Void)?
    var provider: Provider = .claude
    var model: String?
    var sessionId: String?
    var onLoadMore: (() -> Void)?
    var onNavigateToReviewFile: ((String, Int) -> Void)?
    var isPinnedToBottom = true

    // Timeline state — mirrors macOS VC pattern
    var sourceState = ConversationSourceState()
    var uiState = ConversationUIState()
    var messagesByID: [String: TranscriptMessage] = [:]
    var messageMeta: [String: ConversationView.MessageMeta] = [:]
    var turnsByID: [String: TurnSummary] = [:]
    private var projectionResult = ProjectionResult.empty
    private var currentRows: [TimelineRow] = []
    private var rowIndexByTimelineRowID: [TimelineRowID: Int] = [:]
    private var previousMessageCount = 0

    /// Convenience accessors
    var currentMessages: [TranscriptMessage] {
      sourceState.messages
    }

    var chatViewMode: ChatViewMode {
      sourceState.metadata.chatViewMode
    }

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<ConversationSection, TimelineRowID>!

    // Cell registrations
    private var messageCellReg: UICollectionView.CellRegistration<UIKitRichMessageCell, String>!
    private var compactToolCellReg: UICollectionView.CellRegistration<UIKitCompactToolCell, String>!
    private var expandedToolCellReg: UICollectionView.CellRegistration<UIKitExpandedToolCell, String>!
    private var turnHeaderCellReg: UICollectionView.CellRegistration<UIKitTurnHeaderCell, String>!
    private var rollupSummaryCellReg: UICollectionView.CellRegistration<UIKitRollupSummaryCell, String>!
    private var loadMoreCellReg: UICollectionView.CellRegistration<UIKitLoadMoreCell, Void>!
    private var messageCountCellReg: UICollectionView.CellRegistration<UIKitMessageCountCell, Void>!
    private var liveIndicatorCellReg: UICollectionView.CellRegistration<UIKitLiveIndicatorCell, Void>!
    private var spacerCellReg: UICollectionView.CellRegistration<UIKitSpacerCell, Void>!

    private var needsInitialScroll = true
    private var expandedThinkingIDs: Set<String> = []
    /// Cached heights keyed by TimelineRowID. Invalidated on width change.
    private var heightCache: [TimelineRowID: CGFloat] = [:]
    private var lastLayoutWidth: CGFloat = 0
    private let logger = TimelineFileLogger.shared

    override func viewDidLoad() {
      super.viewDidLoad()
      setupCollectionView()
      setupCellRegistrations()
      setupDataSource()
      rebuildSnapshot(animated: false)
    }

    override func viewDidLayoutSubviews() {
      super.viewDidLayoutSubviews()
      let width = collectionView.bounds.width
      if abs(width - lastLayoutWidth) > 0.5, width > 0 {
        lastLayoutWidth = width
        ConversationTimelineReducer.reduce(source: &sourceState, ui: &uiState, action: .widthChanged(width))
        heightCache.removeAll()
        collectionView.collectionViewLayout.invalidateLayout()
      }

      if needsInitialScroll, !currentMessages.isEmpty {
        needsInitialScroll = false
        scrollToBottom(animated: false)
      }
    }

    private func setupCollectionView() {
      let layout = UICollectionViewFlowLayout()
      layout.scrollDirection = .vertical
      layout.minimumLineSpacing = 0
      layout.minimumInteritemSpacing = 0
      layout.estimatedItemSize = .zero // Disable self-sizing — we provide explicit heights

      collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
      collectionView.translatesAutoresizingMaskIntoConstraints = false
      collectionView.backgroundColor = .clear
      collectionView.delegate = self
      collectionView.keyboardDismissMode = .interactive
      collectionView.showsVerticalScrollIndicator = false
      collectionView.showsHorizontalScrollIndicator = false
      collectionView.alwaysBounceHorizontal = false
      collectionView.contentInsetAdjustmentBehavior = .automatic

      view.addSubview(collectionView)
      NSLayoutConstraint.activate([
        collectionView.topAnchor.constraint(equalTo: view.topAnchor),
        collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      ])
    }

    private func setupCellRegistrations() {
      messageCellReg = UICollectionView.CellRegistration<UIKitRichMessageCell, String> {
        [weak self] cell, _, messageId in
        guard let self else { return }
        guard let model = self.buildRichMessageModel(for: messageId) else { return }
        let width = self.collectionView.bounds.width
        cell.configure(model: model, width: width)
        cell.onThinkingExpandToggle = { [weak self] id in
          self?.toggleThinkingExpansion(messageID: id)
        }
      }

      compactToolCellReg = UICollectionView.CellRegistration<UIKitCompactToolCell, String> {
        [weak self] cell, _, messageId in
        guard let self else { return }
        guard let model = self.buildCompactToolModel(for: messageId) else { return }
        cell.configure(model: model)
        cell.onTap = { [weak self] in
          self?.toggleToolExpansion(messageID: messageId)
        }
      }

      expandedToolCellReg = UICollectionView.CellRegistration<UIKitExpandedToolCell, String> {
        [weak self] cell, _, messageId in
        guard let self else { return }
        guard let model = self.buildExpandedToolModel(for: messageId) else { return }
        let width = self.collectionView.bounds.width
        cell.configure(model: model, width: width)
        cell.onCollapse = { [weak self] id in
          self?.toggleToolExpansion(messageID: id)
        }
      }

      turnHeaderCellReg = UICollectionView.CellRegistration<UIKitTurnHeaderCell, String> {
        [weak self] cell, _, turnId in
        guard let self, let turn = self.turnsByID[turnId] else { return }
        cell.configure(turn: turn)
      }

      rollupSummaryCellReg = UICollectionView.CellRegistration<UIKitRollupSummaryCell, String> {
        [weak self] cell, _, rollupId in
        guard let self else { return }
        // Find the row to get payload data
        guard let row = self.currentRows.first(where: { $0.id == .rollupSummary(rollupId) }),
              case let .rollupSummary(_, hiddenCount, totalToolCount, isExpanded, breakdown) = row.payload
        else { return }
        cell.configure(
          hiddenCount: hiddenCount, totalToolCount: totalToolCount,
          isExpanded: isExpanded, breakdown: breakdown
        )
        cell.onToggle = { [weak self] in
          self?.toggleRollup(id: rollupId)
        }
      }

      loadMoreCellReg = UICollectionView.CellRegistration<UIKitLoadMoreCell, Void> {
        [weak self] cell, _, _ in
        guard let self else { return }
        cell.configure(remainingCount: self.sourceState.metadata.remainingLoadCount)
        cell.onLoadMore = self.onLoadMore
      }

      messageCountCellReg = UICollectionView.CellRegistration<UIKitMessageCountCell, Void> {
        [weak self] cell, _, _ in
        guard let self else { return }
        cell.configure(
          displayedCount: self.sourceState.messages.count,
          totalCount: self.sourceState.metadata.messageCount
        )
      }

      liveIndicatorCellReg = UICollectionView.CellRegistration<UIKitLiveIndicatorCell, Void> {
        [weak self] cell, _, _ in
        guard let self else { return }
        let meta = self.sourceState.metadata
        cell.configure(model: UIKitLiveIndicatorCell.Model(
          workStatus: meta.workStatus,
          currentTool: meta.currentTool,
          currentPrompt: meta.currentPrompt,
          pendingToolName: meta.pendingToolName,
          pendingToolInput: meta.pendingToolInput,
          provider: self.provider
        ))
      }

      spacerCellReg = UICollectionView.CellRegistration<UIKitSpacerCell, Void> { _, _, _ in
        // No configuration needed — just a clear cell
      }
    }

    private func setupDataSource() {
      dataSource = UICollectionViewDiffableDataSource<ConversationSection, TimelineRowID>(
        collectionView: collectionView
      ) { [weak self] (
        collectionView: UICollectionView,
        indexPath: IndexPath,
        _: TimelineRowID
      ) -> UICollectionViewCell? in
        guard let self else { return UICollectionViewCell() }
        guard indexPath.item < self.currentRows.count else { return UICollectionViewCell() }
        let row = self.currentRows[indexPath.item]

        switch row.kind {
          case .loadMore:
            return collectionView.dequeueConfiguredReusableCell(
              using: self.loadMoreCellReg, for: indexPath, item: ()
            )
          case .messageCount:
            return collectionView.dequeueConfiguredReusableCell(
              using: self.messageCountCellReg, for: indexPath, item: ()
            )
          case .message:
            if case let .message(id) = row.payload {
              return collectionView.dequeueConfiguredReusableCell(
                using: self.messageCellReg, for: indexPath, item: id
              )
            }
          case .tool:
            if case let .tool(id) = row.payload {
              if self.uiState.expandedToolCards.contains(id) {
                return collectionView.dequeueConfiguredReusableCell(
                  using: self.expandedToolCellReg, for: indexPath, item: id
                )
              } else {
                return collectionView.dequeueConfiguredReusableCell(
                  using: self.compactToolCellReg, for: indexPath, item: id
                )
              }
            }
          case .turnHeader:
            if case let .turnHeader(turnID) = row.payload {
              return collectionView.dequeueConfiguredReusableCell(
                using: self.turnHeaderCellReg, for: indexPath, item: turnID
              )
            }
          case .rollupSummary:
            if case let .rollupSummary(rollupID, _, _, _, _) = row.payload {
              return collectionView.dequeueConfiguredReusableCell(
                using: self.rollupSummaryCellReg, for: indexPath, item: rollupID
              )
            }
          case .liveIndicator:
            return collectionView.dequeueConfiguredReusableCell(
              using: self.liveIndicatorCellReg, for: indexPath, item: ()
            )
          case .bottomSpacer:
            return collectionView.dequeueConfiguredReusableCell(
              using: self.spacerCellReg, for: indexPath, item: ()
            )
        }
        return UICollectionViewCell()
      }
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

      messagesByID = Dictionary(uniqueKeysWithValues: sourceState.messages.map { ($0.id, $0) })
      messageMeta = ConversationView.computeMessageMetadata(sourceState.messages)

      rebuildTurns()
      ConversationTimelineReducer.reduce(
        source: &sourceState,
        ui: &uiState,
        action: .setPinnedToBottom(isPinnedToBottom)
      )
    }

    func rebuildSnapshot(animated: Bool = false) {
      guard dataSource != nil else { return }
      let previousProjection = projectionResult
      projectionResult = ConversationTimelineProjector.project(
        source: sourceState,
        ui: uiState,
        previous: previousProjection
      )
      currentRows = projectionResult.rows
      rebuildRowLookup()

      logger.info(
        "rebuildSnapshot rows=\(currentRows.count) msgs=\(sourceState.messages.count) "
          + "turns=\(sourceState.turns.count) mode=\(chatViewMode) "
          + "w=\(Self.f(collectionView.bounds.width))"
      )

      heightCache.removeAll()
      var snapshot = NSDiffableDataSourceSnapshot<ConversationSection, TimelineRowID>()
      snapshot.appendSections([.main])
      snapshot.appendItems(currentRows.map(\.id))
      dataSource.apply(snapshot, animatingDifferences: animated)
    }

    func applyProjectionUpdate() {
      guard dataSource != nil else { return }
      let previous = projectionResult
      let next = ConversationTimelineProjector.project(
        source: sourceState,
        ui: uiState,
        previous: previous
      )
      let oldIDs = currentRows.map(\.id)
      let newIDs = next.rows.map(\.id)
      let structureChanged = oldIDs != newIDs

      // Capture scroll anchor before applying changes when not pinned to bottom
      let isPrepend = !isPinnedToBottom
        && ConversationScrollAnchorMath.isPrependTransition(from: oldIDs, to: newIDs)
      var savedAnchor: (rowID: TimelineRowID, delta: Double)?
      if isPrepend {
        savedAnchor = captureTopVisibleAnchor()
      }

      if structureChanged {
        projectionResult = next
        currentRows = next.rows
        rebuildRowLookup()
        for dirtyID in next.dirtyRowIDs {
          heightCache.removeValue(forKey: dirtyID)
        }
        var snapshot = NSDiffableDataSourceSnapshot<ConversationSection, TimelineRowID>()
        snapshot.appendSections([.main])
        snapshot.appendItems(currentRows.map(\.id))
        dataSource.apply(snapshot, animatingDifferences: false)
      } else {
        // Content-only update — reconfigure dirty rows
        projectionResult = next
        currentRows = next.rows

        var reconfigureIDs: [TimelineRowID] = []
        for dirtyID in next.dirtyRowIDs {
          heightCache.removeValue(forKey: dirtyID)
          reconfigureIDs.append(dirtyID)
        }

        if !reconfigureIDs.isEmpty {
          var snapshot = dataSource.snapshot()
          snapshot.reconfigureItems(reconfigureIDs)
          dataSource.apply(snapshot, animatingDifferences: false)
          // Heights may have changed — force layout to re-query sizeForItemAt
          collectionView.collectionViewLayout.invalidateLayout()
        }
      }

      // Restore scroll anchor after prepend
      if let anchor = savedAnchor {
        restoreScrollAnchor(anchor)
      } else if isPinnedToBottom {
        scrollToBottom(animated: false)
      } else if sourceState.messages.count > previousMessageCount {
        let delta = sourceState.messages.count - previousMessageCount
        coordinator?.unreadDelta(delta)
      }
      previousMessageCount = sourceState.messages.count
    }

    // MARK: - Scroll Anchor

    private func captureTopVisibleAnchor() -> (rowID: TimelineRowID, delta: Double)? {
      guard !currentRows.isEmpty else { return nil }
      let visiblePaths = collectionView.indexPathsForVisibleItems.sorted()
      guard let topPath = visiblePaths.first else { return nil }
      let row = topPath.item
      guard row >= 0, row < currentRows.count else { return nil }

      let attrs = collectionView.layoutAttributesForItem(at: topPath)
      guard let rowTopY = attrs?.frame.minY else { return nil }
      let viewportTopY = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
      let delta = ConversationScrollAnchorMath.captureDelta(
        viewportTopY: viewportTopY,
        rowTopY: rowTopY
      )
      return (rowID: currentRows[row].id, delta: delta)
    }

    private func restoreScrollAnchor(_ anchor: (rowID: TimelineRowID, delta: Double)) {
      guard let row = rowIndexByTimelineRowID[anchor.rowID], row >= 0, row < currentRows.count else { return }
      collectionView.layoutIfNeeded()
      let indexPath = IndexPath(item: row, section: 0)
      guard let attrs = collectionView.layoutAttributesForItem(at: indexPath) else { return }
      let rowTopY = attrs.frame.minY
      let insetTop = collectionView.adjustedContentInset.top
      let contentHeight = collectionView.contentSize.height
      let viewportHeight = collectionView.bounds.height - insetTop - collectionView.adjustedContentInset.bottom
      let targetY = ConversationScrollAnchorMath.restoredViewportTop(
        rowTopY: rowTopY,
        deltaFromRowTop: anchor.delta,
        contentHeight: contentHeight,
        viewportHeight: viewportHeight
      ) - insetTop
      collectionView.setContentOffset(CGPoint(x: 0, y: targetY), animated: false)
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

    private func rebuildRowLookup() {
      rowIndexByTimelineRowID.removeAll(keepingCapacity: true)
      for (index, row) in currentRows.enumerated() {
        rowIndexByTimelineRowID[row.id] = index
      }
    }

    func scrollToBottom(animated: Bool) {
      guard let dataSource, !dataSource.snapshot().itemIdentifiers.isEmpty else { return }
      let items = dataSource.snapshot().itemIdentifiers(inSection: .main)
      guard !items.isEmpty else { return }
      let lastIndex = items.count - 1
      let indexPath = IndexPath(item: lastIndex, section: 0)
      collectionView.scrollToItem(at: indexPath, at: .bottom, animated: animated)
    }

    // MARK: - UIScrollViewDelegate

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

    private func checkRepinIfNearBottom(_ scrollView: UIScrollView) {
      let offsetY = scrollView.contentOffset.y
      let contentHeight = scrollView.contentSize.height
      let frameHeight = scrollView.frame.height
      let distanceFromBottom = contentHeight - offsetY - frameHeight

      if distanceFromBottom < 60 {
        isPinnedToBottom = true
        coordinator?.pinnedChanged(true)
        coordinator?.unreadReset()
      }
    }

    // MARK: - UICollectionViewDelegateFlowLayout

    private static func f(_ v: CGFloat) -> String {
      String(format: "%.1f", v)
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

      if let cached = heightCache[row.id] {
        return CGSize(width: width, height: cached)
      }

      let height: CGFloat
      switch row.kind {
        case .bottomSpacer:
          height = ConversationLayout.bottomSpacerHeight
        case .turnHeader:
          height = ConversationLayout.turnHeaderHeight
        case .rollupSummary:
          height = ConversationLayout.rollupSummaryHeight
        case .loadMore:
          height = ConversationLayout.loadMoreHeight
        case .messageCount:
          height = ConversationLayout.messageCountHeight
        case .tool:
          if case let .tool(id) = row.payload, uiState.expandedToolCards.contains(id),
             let toolModel = buildExpandedToolModel(for: id)
          {
            height = ExpandedToolLayout.requiredHeight(for: width, model: toolModel)
            logger.debug("sizeForItem[\(indexPath.item)] tool[\(id.prefix(8))] expanded h=\(Self.f(height))")
          } else if case let .tool(id) = row.payload {
            if let message = messagesByID[id] {
              let summary = CompactToolHelpers.summary(for: message)
              height = UIKitCompactToolCell.requiredHeight(for: width, summary: summary)
            } else {
              height = ConversationLayout.compactToolRowHeight
            }
            logger.debug("sizeForItem[\(indexPath.item)] tool[\(id.prefix(8))] compact h=\(Self.f(height))")
          } else {
            height = ConversationLayout.compactToolRowHeight
          }
        case .message:
          if case let .message(id) = row.payload, let model = buildRichMessageModel(for: id) {
            height = UIKitRichMessageCell.requiredHeight(for: width, model: model)
            logger.debug(
              "sizeForItem[\(indexPath.item)] msg[\(id.prefix(8))] \(model.messageType) "
                + "h=\(Self.f(height)) w=\(Self.f(width))"
            )
          } else {
            height = 44
            logger.debug("sizeForItem[\(indexPath.item)] msg fallback h=44")
          }
        case .liveIndicator:
          height = UIKitLiveIndicatorCell.cellHeight
      }

      heightCache[row.id] = height
      return CGSize(width: width, height: height)
    }

    // MARK: - Model Building

    private func buildRichMessageModel(for messageId: String) -> NativeRichMessageRowModel? {
      guard let message = messagesByID[messageId] else { return nil }
      return SharedModelBuilders.richMessageModel(
        from: message,
        messageID: messageId,
        isThinkingExpanded: expandedThinkingIDs.contains(messageId)
      )
    }

    // MARK: - Thinking Expansion

    private func toggleThinkingExpansion(messageID: String) {
      if expandedThinkingIDs.contains(messageID) {
        expandedThinkingIDs.remove(messageID)
      } else {
        expandedThinkingIDs.insert(messageID)
      }
      // Invalidate cached height and reconfigure
      let rowID = TimelineRowID.message(messageID)
      heightCache.removeValue(forKey: rowID)
      var snapshot = dataSource.snapshot()
      snapshot.reconfigureItems([rowID])
      dataSource.apply(snapshot, animatingDifferences: true)
    }

    // MARK: - Compact Tool Model Building

    private func buildCompactToolModel(for messageId: String) -> NativeCompactToolRowModel? {
      guard let message = messagesByID[messageId] else { return nil }
      guard message.isTool else { return nil }
      return SharedModelBuilders.compactToolModel(from: message)
    }

    private func buildExpandedToolModel(for messageId: String) -> NativeExpandedToolModel? {
      guard let message = messagesByID[messageId] else {
        logger.debug("expandedToolModel[\(messageId.prefix(8))] — message not found")
        return nil
      }
      guard message.isTool else {
        logger.debug("expandedToolModel[\(messageId.prefix(8))] — not a tool (type=\(message.type.rawValue))")
        return nil
      }

      logger.debug(
        "expandedToolModel[\(messageId.prefix(8))] tool=\(message.toolName ?? "?") "
          + "hasOutput=\(message.toolOutput != nil) "
          + "outputLen=\(message.toolOutput?.count ?? 0) "
          + "hasInput=\(message.toolInput != nil) "
          + "inputKeys=\(message.toolInput?.keys.sorted().joined(separator: ",") ?? "nil") "
          + "content=\(message.content.prefix(60))"
      )

      return SharedModelBuilders.expandedToolModel(from: message, messageID: messageId)
    }

    // MARK: - Tool Expansion

    private func toggleToolExpansion(messageID: String) {
      let wasExpanded = uiState.expandedToolCards.contains(messageID)
      ConversationTimelineReducer.reduce(source: &sourceState, ui: &uiState, action: .toggleToolCard(messageID))
      logger.debug("toggleToolExpansion[\(messageID.prefix(8))] \(wasExpanded ? "collapse" : "expand")")
      // Invalidate cached height for this tool row
      let toolRowID = currentRows.first(where: {
        if case let .tool(id) = $0.payload { return id == messageID }
        return false
      })?.id
      if let toolRowID { heightCache.removeValue(forKey: toolRowID) }

      // Rebuild snapshot, then force-reload the toggled tool row.
      // Without reloadItems, the diffable data source sees "same IDs"
      // and keeps the old cell (compact at expanded height = blank space).
      // reloadItems deletes the old cell and dequeues a fresh one,
      // allowing the cell type to change (compact ↔ expanded).
      rebuildSnapshot(animated: false)
      if let toolRowID {
        var snapshot = dataSource.snapshot()
        snapshot.reloadItems([toolRowID])
        dataSource.apply(snapshot, animatingDifferences: false)
      }
    }

    // MARK: - Rollup Toggle

    private func toggleRollup(id: String) {
      ConversationTimelineReducer.reduce(source: &sourceState, ui: &uiState, action: .toggleRollup(id))
      applyProjectionUpdate()
    }
  }

  // MARK: - macOS Implementation

#elseif os(macOS)

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

    struct NativeMessageRowModel {
      let speaker: String
      let body: String
      let speakerColor: NSColor
      let textColor: NSColor
      let bubbleColor: NSColor
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

    // MARK: - Native Structural Cells

    private final class NativeSpacerCellView: NSTableCellView {
      static let reuseIdentifier = NSUserInterfaceItemIdentifier("conversationNativeSpacerCell")

      override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
      }

      required init?(coder: NSCoder) {
        super.init(coder: coder)
      }
    }

    private final class NativeTurnHeaderCellView: NSTableCellView {
      static let reuseIdentifier = NSUserInterfaceItemIdentifier("conversationNativeTurnHeaderCell")

      private let dividerLine = NSView()
      private let turnLabel = NSTextField(labelWithString: "")
      private let statusCapsule = NSView()
      private let statusLabel = NSTextField(labelWithString: "")
      private let toolsLabel = NSTextField(labelWithString: "")

      override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
      }

      required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
      }

      private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        // Subtle horizontal divider at the top of the cell
        dividerLine.wantsLayer = true
        dividerLine.layer?.backgroundColor = NSColor(Color.textQuaternary).withAlphaComponent(0.5).cgColor
        dividerLine.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dividerLine)

        turnLabel.translatesAutoresizingMaskIntoConstraints = false
        turnLabel.font = Self.roundedFont(size: 10, weight: .bold)
        turnLabel.textColor = NSColor(Color.textSecondary)
        turnLabel.lineBreakMode = .byTruncatingTail
        addSubview(turnLabel)

        statusCapsule.translatesAutoresizingMaskIntoConstraints = false
        statusCapsule.wantsLayer = true
        statusCapsule.layer?.cornerRadius = 8
        statusCapsule.layer?.masksToBounds = true
        addSubview(statusCapsule)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = Self.roundedFont(size: 9, weight: .bold)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusCapsule.addSubview(statusLabel)

        toolsLabel.translatesAutoresizingMaskIntoConstraints = false
        toolsLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        toolsLabel.textColor = NSColor(Color.textTertiary)
        toolsLabel.lineBreakMode = .byTruncatingTail
        addSubview(toolsLabel)

        let inset = ConversationLayout.laneHorizontalInset
        NSLayoutConstraint.activate([
          dividerLine.topAnchor.constraint(equalTo: topAnchor, constant: 4),
          dividerLine.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
          dividerLine.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
          dividerLine.heightAnchor.constraint(equalToConstant: 1),

          turnLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
          turnLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 4),

          statusCapsule.leadingAnchor.constraint(equalTo: turnLabel.trailingAnchor, constant: 10),
          statusCapsule.centerYAnchor.constraint(equalTo: turnLabel.centerYAnchor),

          statusLabel.topAnchor.constraint(equalTo: statusCapsule.topAnchor, constant: 3),
          statusLabel.bottomAnchor.constraint(equalTo: statusCapsule.bottomAnchor, constant: -3),
          statusLabel.leadingAnchor.constraint(equalTo: statusCapsule.leadingAnchor, constant: 7),
          statusLabel.trailingAnchor.constraint(equalTo: statusCapsule.trailingAnchor, constant: -7),

          toolsLabel.leadingAnchor.constraint(equalTo: statusCapsule.trailingAnchor, constant: 10),
          toolsLabel.centerYAnchor.constraint(equalTo: turnLabel.centerYAnchor),
        ])
      }

      func configure(turn: TurnSummary) {
        // Uppercase labels need wider tracking for legibility (Typography.md §Micro-Typography)
        let turnAttrs: [NSAttributedString.Key: Any] = [
          .font: turnLabel.font as Any,
          .foregroundColor: turnLabel.textColor as Any,
          .kern: 1.0,
        ]
        turnLabel.attributedStringValue = NSAttributedString(
          string: "TURN \(turn.turnNumber)",
          attributes: turnAttrs
        )

        let (label, color) = statusInfo(for: turn.status)
        let statusAttrs: [NSAttributedString.Key: Any] = [
          .font: statusLabel.font as Any,
          .foregroundColor: color,
          .kern: 0.8,
        ]
        statusLabel.attributedStringValue = NSAttributedString(string: label, attributes: statusAttrs)
        statusCapsule.layer?.backgroundColor = color.withAlphaComponent(0.16).cgColor

        if turn.toolsUsed.isEmpty {
          toolsLabel.isHidden = true
        } else {
          toolsLabel.isHidden = false
          toolsLabel.stringValue = "\(turn.toolsUsed.count) tools"
        }
      }

      private static func roundedFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let rounded = base.fontDescriptor.withDesign(.rounded) {
          return NSFont(descriptor: rounded, size: size) ?? base
        }
        return base
      }

      private func statusInfo(for status: TurnStatus) -> (String, NSColor) {
        switch status {
          case .active:
            ("ACTIVE", NSColor(Color.accent))
          case .completed:
            ("DONE", NSColor(Color.textTertiary))
          case .failed:
            ("FAILED", NSColor(calibratedRed: 0.95, green: 0.48, blue: 0.42, alpha: 1))
        }
      }
    }

    private final class NativeRollupSummaryCellView: NSTableCellView {
      static let reuseIdentifier = NSUserInterfaceItemIdentifier("conversationNativeRollupSummaryCell")

      private let accentLine = NSView()
      private let backgroundBox = NSView()
      private let chevronImage = NSImageView()
      private let countLabel = NSTextField(labelWithString: "")
      private let actionsLabel = NSTextField(labelWithString: "")
      private let separatorDot = NSView()
      private let breakdownStack = NSStackView()
      private var isHovering = false
      private var trackingArea: NSTrackingArea?
      var onToggle: (() -> Void)?

      override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
      }

      required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
      }

      private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        let inset = ConversationLayout.laneHorizontalInset

        // Thin left accent line — visual thread connector
        accentLine.wantsLayer = true
        accentLine.layer?.backgroundColor = NSColor(Color.textQuaternary).withAlphaComponent(0.4).cgColor
        accentLine.translatesAutoresizingMaskIntoConstraints = false
        addSubview(accentLine)

        // Background pill
        backgroundBox.translatesAutoresizingMaskIntoConstraints = false
        backgroundBox.wantsLayer = true
        backgroundBox.layer?.cornerRadius = Radius.lg
        backgroundBox.layer?.masksToBounds = true
        backgroundBox.layer?.backgroundColor = NSColor(Color.backgroundTertiary).withAlphaComponent(0.7).cgColor
        backgroundBox.layer?.borderWidth = 0.5
        backgroundBox.layer?.borderColor = NSColor(Color.surfaceBorder).withAlphaComponent(0.4).cgColor
        addSubview(backgroundBox)

        // Chevron
        chevronImage.translatesAutoresizingMaskIntoConstraints = false
        chevronImage.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        backgroundBox.addSubview(chevronImage)

        // Count — bold monospaced
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        countLabel.textColor = NSColor(Color.textPrimary)
        backgroundBox.addSubview(countLabel)

        // "actions" label
        actionsLabel.translatesAutoresizingMaskIntoConstraints = false
        actionsLabel.font = NSFont.systemFont(ofSize: TypeScale.body, weight: .medium)
        actionsLabel.textColor = NSColor(Color.textSecondary)
        actionsLabel.stringValue = "actions"
        backgroundBox.addSubview(actionsLabel)

        // Separator dot
        separatorDot.translatesAutoresizingMaskIntoConstraints = false
        separatorDot.wantsLayer = true
        separatorDot.layer?.cornerRadius = 1.5
        separatorDot.layer?.backgroundColor = NSColor(Color.surfaceBorder).cgColor
        backgroundBox.addSubview(separatorDot)

        // Tool breakdown stack
        breakdownStack.translatesAutoresizingMaskIntoConstraints = false
        breakdownStack.orientation = .horizontal
        breakdownStack.spacing = 12
        breakdownStack.alignment = .centerY
        backgroundBox.addSubview(breakdownStack)

        NSLayoutConstraint.activate([
          accentLine.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset + 6),
          accentLine.widthAnchor.constraint(equalToConstant: 2),
          accentLine.topAnchor.constraint(equalTo: topAnchor),
          accentLine.bottomAnchor.constraint(equalTo: bottomAnchor),

          backgroundBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset + 16),
          backgroundBox.trailingAnchor.constraint(
            lessThanOrEqualTo: trailingAnchor,
            constant: -inset
          ),
          backgroundBox.topAnchor.constraint(equalTo: topAnchor, constant: 4),
          backgroundBox.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),

          chevronImage.leadingAnchor.constraint(equalTo: backgroundBox.leadingAnchor, constant: 14),
          chevronImage.centerYAnchor.constraint(equalTo: backgroundBox.centerYAnchor),
          chevronImage.widthAnchor.constraint(equalToConstant: 10),

          countLabel.leadingAnchor.constraint(equalTo: chevronImage.trailingAnchor, constant: 6),
          countLabel.centerYAnchor.constraint(equalTo: backgroundBox.centerYAnchor),

          actionsLabel.leadingAnchor.constraint(equalTo: countLabel.trailingAnchor, constant: 4),
          actionsLabel.centerYAnchor.constraint(equalTo: backgroundBox.centerYAnchor),

          separatorDot.leadingAnchor.constraint(equalTo: actionsLabel.trailingAnchor, constant: 16),
          separatorDot.centerYAnchor.constraint(equalTo: backgroundBox.centerYAnchor),
          separatorDot.widthAnchor.constraint(equalToConstant: 3),
          separatorDot.heightAnchor.constraint(equalToConstant: 3),

          breakdownStack.leadingAnchor.constraint(equalTo: separatorDot.trailingAnchor, constant: 16),
          breakdownStack.centerYAnchor.constraint(equalTo: backgroundBox.centerYAnchor),
          breakdownStack.trailingAnchor.constraint(
            lessThanOrEqualTo: backgroundBox.trailingAnchor,
            constant: -14
          ),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
        addGestureRecognizer(click)
      }

      override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
          rect: bounds,
          options: [.mouseEnteredAndExited, .activeInActiveApp],
          owner: self
        )
        addTrackingArea(area)
        trackingArea = area
      }

      override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateHoverState()
      }

      override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateHoverState()
      }

      private func updateHoverState() {
        NSAnimationContext.runAnimationGroup { ctx in
          ctx.duration = 0.15
          ctx.allowsImplicitAnimation = true
          backgroundBox.layer?.backgroundColor = isHovering
            ? NSColor(Color.backgroundTertiary).cgColor
            : NSColor(Color.backgroundTertiary).withAlphaComponent(0.7).cgColor
          backgroundBox.layer?.borderColor = isHovering
            ? NSColor(Color.accent).withAlphaComponent(0.15).cgColor
            : NSColor(Color.surfaceBorder).withAlphaComponent(0.4).cgColor
          chevronImage.contentTintColor = isHovering
            ? NSColor(Color.accent)
            : NSColor(Color.textSecondary)
        }
      }

      @objc private func handleClick(_ sender: NSClickGestureRecognizer) {
        onToggle?()
      }

      func configure(
        hiddenCount: Int, totalToolCount: Int, isExpanded: Bool,
        breakdown: [ToolBreakdownEntry]
      ) {
        let symbolName = isExpanded ? "chevron.down" : "chevron.right"
        chevronImage.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)

        let lineColor = isExpanded
          ? NSColor(Color.textQuaternary).withAlphaComponent(0.3)
          : NSColor(Color.textQuaternary).withAlphaComponent(0.4)
        accentLine.layer?.backgroundColor = lineColor.cgColor

        if isExpanded {
          chevronImage.contentTintColor = NSColor(Color.textTertiary)
          countLabel.isHidden = true
          actionsLabel.textColor = NSColor(Color.textTertiary)
          actionsLabel.stringValue = "Collapse tools"
          separatorDot.isHidden = true
          breakdownStack.isHidden = true
          backgroundBox.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.02).cgColor
          backgroundBox.layer?.borderColor = NSColor.clear.cgColor
        } else {
          chevronImage.contentTintColor = NSColor(Color.textSecondary)
          countLabel.isHidden = false
          countLabel.stringValue = "\(hiddenCount)"
          actionsLabel.textColor = NSColor(Color.textSecondary)
          actionsLabel.stringValue = "actions"
          separatorDot.isHidden = breakdown.isEmpty
          breakdownStack.isHidden = breakdown.isEmpty
          backgroundBox.layer?.backgroundColor =
            NSColor(Color.backgroundTertiary).withAlphaComponent(0.7).cgColor
          backgroundBox.layer?.borderColor =
            NSColor(Color.surfaceBorder).withAlphaComponent(0.4).cgColor

          rebuildBreakdownChips(breakdown)
        }
      }

      private func rebuildBreakdownChips(_ breakdown: [ToolBreakdownEntry]) {
        breakdownStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for entry in breakdown.prefix(6) {
          let chip = NSStackView()
          chip.orientation = .horizontal
          chip.spacing = 5
          chip.alignment = .centerY

          let icon = NSImageView()
          icon.image = NSImage(systemSymbolName: entry.icon, accessibilityDescription: nil)
          icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
          icon.contentTintColor = NSColor(Self.toolColor(for: entry.colorKey))
          icon.translatesAutoresizingMaskIntoConstraints = false
          icon.widthAnchor.constraint(equalToConstant: 12).isActive = true

          let count = NSTextField(labelWithString: "\(entry.count)")
          count.font = NSFont.monospacedDigitSystemFont(ofSize: TypeScale.body, weight: .bold)
          count.textColor = NSColor(Color.textSecondary)

          let name = NSTextField(labelWithString: Self.displayName(for: entry.name))
          name.font = NSFont.systemFont(ofSize: TypeScale.body, weight: .medium)
          name.textColor = NSColor(Color.textTertiary)
          name.lineBreakMode = .byTruncatingTail

          chip.addArrangedSubview(icon)
          chip.addArrangedSubview(count)
          chip.addArrangedSubview(name)
          breakdownStack.addArrangedSubview(chip)
        }
      }

      private static func toolColor(for key: String) -> Color {
        switch key {
          case "bash": .toolBash
          case "read": .toolRead
          case "write": .toolWrite
          case "search": .toolSearch
          case "task": .toolTask
          case "web": .toolWeb
          case "skill": .toolSkill
          case "plan": .toolPlan
          case "todo": .toolTodo
          case "question": .toolQuestion
          case "mcp": .toolMcp
          default: .textSecondary
        }
      }

      private static func displayName(for toolName: String) -> String {
        let lowered = toolName.lowercased()
        switch lowered {
          case "bash": return "Bash"
          case "read": return "Read"
          case "edit": return "Edit"
          case "write": return "Write"
          case "glob": return "Glob"
          case "grep": return "Grep"
          case "task": return "Task"
          case "webfetch": return "Fetch"
          case "websearch": return "Search"
          case "skill": return "Skill"
          case "enterplanmode", "exitplanmode": return "Plan"
          case "taskcreate", "taskupdate", "tasklist", "taskget": return "Todo"
          case "askuserquestion": return "Question"
          case "notebookedit": return "Notebook"
          default:
            if toolName.hasPrefix("mcp__") {
              return toolName
                .replacingOccurrences(of: "mcp__", with: "")
                .components(separatedBy: "__").last ?? "MCP"
            }
            return toolName
        }
      }
    }

    private final class NativeLoadMoreCellView: NSTableCellView {
      static let reuseIdentifier = NSUserInterfaceItemIdentifier("conversationNativeLoadMoreCell")

      private let button = NSButton(title: "", target: nil, action: nil)
      var onLoadMore: (() -> Void)?

      override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
      }

      required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
      }

      private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        button.contentTintColor = NSColor(Color.accent)
        button.target = self
        button.action = #selector(handleClick)
        addSubview(button)

        NSLayoutConstraint.activate([
          button.centerXAnchor.constraint(equalTo: centerXAnchor),
          button.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
      }

      @objc private func handleClick() {
        onLoadMore?()
      }

      func configure(remainingCount: Int) {
        button.title = "Load \(remainingCount) earlier messages"
      }
    }

    private final class NativeMessageCountCellView: NSTableCellView {
      static let reuseIdentifier = NSUserInterfaceItemIdentifier("conversationNativeMessageCountCell")

      private let label = NSTextField(labelWithString: "")

      override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
      }

      required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
      }

      private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        label.textColor = NSColor(Color.textTertiary)
        label.alignment = .center
        addSubview(label)

        NSLayoutConstraint.activate([
          label.centerXAnchor.constraint(equalTo: centerXAnchor),
          label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
      }

      func configure(displayedCount: Int, totalCount: Int) {
        label.stringValue = "Showing \(displayedCount) of \(totalCount) messages"
      }
    }

    // MARK: - Native Compact Tool Cell

    private final class NativeCompactToolCellView: NSTableCellView {
      static let reuseIdentifier = NSUserInterfaceItemIdentifier("conversationNativeCompactToolCell")

      private let threadLine = NSView()
      private let glyphImage = NSImageView()
      private let summaryField = NSTextField(labelWithString: "")
      private let metaField = NSTextField(labelWithString: "")
      var onTap: (() -> Void)?

      override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
      }

      required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
      }

      private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        let inset = ConversationLayout.laneHorizontalInset

        // Thread line — connects to rollup above/below
        threadLine.wantsLayer = true
        threadLine.layer?.backgroundColor = NSColor(Color.textQuaternary).withAlphaComponent(0.4).cgColor
        threadLine.translatesAutoresizingMaskIntoConstraints = false
        addSubview(threadLine)

        glyphImage.translatesAutoresizingMaskIntoConstraints = false
        glyphImage.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
        addSubview(glyphImage)

        summaryField.translatesAutoresizingMaskIntoConstraints = false
        summaryField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        summaryField.textColor = NSColor.white.withAlphaComponent(0.58)
        summaryField.lineBreakMode = .byCharWrapping
        summaryField.maximumNumberOfLines = 0
        summaryField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(summaryField)

        metaField.translatesAutoresizingMaskIntoConstraints = false
        metaField.font = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .medium)
        metaField.textColor = NSColor(Color.textTertiary)
        metaField.lineBreakMode = .byTruncatingTail
        metaField.alignment = .right
        metaField.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(metaField)

        NSLayoutConstraint.activate([
          threadLine.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset + 6),
          threadLine.widthAnchor.constraint(equalToConstant: 2),
          threadLine.topAnchor.constraint(equalTo: topAnchor),
          threadLine.bottomAnchor.constraint(equalTo: bottomAnchor),

          glyphImage.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset + 16),
          glyphImage.topAnchor.constraint(equalTo: topAnchor, constant: 8),
          glyphImage.widthAnchor.constraint(equalToConstant: 18),

          summaryField.leadingAnchor.constraint(equalTo: glyphImage.trailingAnchor, constant: 4),
          summaryField.topAnchor.constraint(equalTo: topAnchor, constant: 6),
          summaryField.trailingAnchor.constraint(lessThanOrEqualTo: metaField.leadingAnchor, constant: -8),
          summaryField.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -6),

          metaField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
          metaField.topAnchor.constraint(equalTo: topAnchor, constant: 8),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
        addGestureRecognizer(click)
      }

      @objc private func handleClick(_ sender: NSClickGestureRecognizer) {
        onTap?()
      }

      static func requiredHeight(for width: CGFloat, summary: String) -> CGFloat {
        let inset = ConversationLayout.laneHorizontalInset
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        // glyph leading: inset + 16 + 18 (glyph) + 4 (gap) = inset + 38
        // meta trailing area ~ 60pt reserve
        let textWidth = max(60, width - inset * 2 - 38 - 60)
        let textH = ExpandedToolLayout.measuredTextHeight(summary, font: font, maxWidth: textWidth)
        return max(ConversationLayout.compactToolRowHeight, textH + 12)
      }

      func configure(model: NativeCompactToolRowModel) {
        glyphImage.image = NSImage(systemSymbolName: model.glyphSymbol, accessibilityDescription: nil)
        glyphImage.contentTintColor = model.glyphColor.withAlphaComponent(0.7)
        summaryField.stringValue = model.summary
        glyphImage.alphaValue = model.isInProgress ? 0.4 : 0.8

        if let meta = model.rightMeta {
          metaField.isHidden = false
          metaField.stringValue = meta
        } else {
          metaField.isHidden = true
        }
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

    // MARK: - Native Message Cell

    private final class NativeMessageTableCellView: NSTableCellView {
      static let reuseIdentifier = NSUserInterfaceItemIdentifier("conversationNativeMessageTableCell")

      private let bubbleView = NSView()
      private let speakerField = NSTextField(labelWithString: "")
      private let bodyField = NSTextField(wrappingLabelWithString: "")

      private let speakerFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
      private let bodyFont = NSFont.systemFont(ofSize: 13)
      private let outerVerticalPadding: CGFloat = 12
      private let outerHorizontalPadding: CGFloat = 24
      private let bubbleHorizontalPadding: CGFloat = 20
      private let bubbleVerticalPadding: CGFloat = 19
      private let speakerToBodySpacing: CGFloat = 5

      override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
      }

      required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
      }

      private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        bubbleView.wantsLayer = true
        bubbleView.layer?.masksToBounds = true
        bubbleView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bubbleView)

        speakerField.translatesAutoresizingMaskIntoConstraints = false
        speakerField.font = speakerFont
        speakerField.lineBreakMode = .byTruncatingTail
        speakerField.maximumNumberOfLines = 1
        speakerField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bubbleView.addSubview(speakerField)

        bodyField.translatesAutoresizingMaskIntoConstraints = false
        bodyField.font = bodyFont
        bodyField.lineBreakMode = .byCharWrapping
        bodyField.maximumNumberOfLines = 0
        bodyField.usesSingleLineMode = false
        bodyField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bodyField.cell?.wraps = true
        bodyField.cell?.isScrollable = false
        bodyField.cell?.lineBreakMode = .byCharWrapping
        bodyField.cell?.truncatesLastVisibleLine = false
        bubbleView.addSubview(bodyField)

        NSLayoutConstraint.activate([
          bubbleView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
          bubbleView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
          bubbleView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
          bubbleView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

          speakerField.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: 9),
          speakerField.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: 10),
          speakerField.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -10),

          bodyField.topAnchor.constraint(equalTo: speakerField.bottomAnchor, constant: 5),
          bodyField.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: 10),
          bodyField.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -10),
          bodyField.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: -10),
        ])
      }

      func configure(model: NativeMessageRowModel) {
        speakerField.stringValue = model.speaker
        speakerField.textColor = model.speakerColor
        bodyField.attributedStringValue = buildAttributedBody(text: model.body, textColor: model.textColor)
        bubbleView.layer?.backgroundColor = model.bubbleColor.cgColor
        bubbleView.layer?.cornerRadius = 9
      }

      func requiredHeight(for width: CGFloat, model: NativeMessageRowModel) -> CGFloat {
        guard width > 1 else { return 1 }
        let textWidth = max(44, width - outerHorizontalPadding - bubbleHorizontalPadding)

        let speakerHeight = ceil(speakerFont.ascender - speakerFont.descender + speakerFont.leading)

        let attrBody = buildAttributedBody(text: model.body, textColor: model.textColor)
        let bodyRect = attrBody.boundingRect(
          with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
          options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let minBodyHeight = ceil(bodyFont.ascender - bodyFont.descender + bodyFont.leading)
        let bodyHeight = max(minBodyHeight, ceil(bodyRect.height))

        return max(1, ceil(
          outerVerticalPadding + bubbleVerticalPadding + speakerHeight + speakerToBodySpacing + bodyHeight
        ))
      }

      // MARK: - Inline Code Attributed String Builder

      private let codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

      /// Parses inline code spans (`` `text` ``) from plain text and returns an
      /// attributed string with monospace font for code segments. Fast path skips
      /// parsing entirely when no backticks are present.
      private func buildAttributedBody(text: String, textColor: NSColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping

        let baseAttrs: [NSAttributedString.Key: Any] = [
          .font: bodyFont,
          .foregroundColor: textColor,
          .paragraphStyle: paragraph,
        ]

        guard text.contains("`") else {
          return NSAttributedString(string: text, attributes: baseAttrs)
        }

        let codeAttrs: [NSAttributedString.Key: Any] = [
          .font: codeFont,
          .foregroundColor: textColor,
          .paragraphStyle: paragraph,
        ]

        let result = NSMutableAttributedString()
        var i = text.startIndex

        while i < text.endIndex {
          if text[i] == "`" {
            let afterTick = text.index(after: i)
            guard afterTick < text.endIndex else {
              result.append(NSAttributedString(string: "`", attributes: baseAttrs))
              break
            }
            if let closingTick = text[afterTick...].firstIndex(of: "`") {
              let codeContent = String(text[afterTick ..< closingTick])
              if codeContent.isEmpty {
                i = text.index(after: closingTick)
              } else {
                result.append(NSAttributedString(string: codeContent, attributes: codeAttrs))
                i = text.index(after: closingTick)
              }
            } else {
              // Unmatched backtick — render as literal
              result.append(NSAttributedString(string: "`", attributes: baseAttrs))
              i = afterTick
            }
          } else {
            let nextTick = text[i...].firstIndex(of: "`") ?? text.endIndex
            result.append(NSAttributedString(string: String(text[i ..< nextTick]), attributes: baseAttrs))
            i = nextTick
          }
        }

        return result
      }
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

  private final class HostingTableCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("conversationHostingTableCell")

    private var hostingView: LayoutObservingHostingView?
    private var isConfiguringContent = false
    private var isMeasuringHeight = false
    var onContentHeightDidChange: ((CGFloat) -> Void)?

    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      setup()
    }

    required init?(coder: NSCoder) {
      super.init(coder: coder)
      setup()
    }

    private func setup() {
      wantsLayer = true
      layer?.backgroundColor = NSColor.clear.cgColor
      canDrawSubviewsIntoLayer = true
    }

    func clearContent() {
      isConfiguringContent = true
      defer { isConfiguringContent = false }
      hostingView?.rootView = AnyView(EmptyView())
    }

    func configure(with content: AnyView, maxWidth: CGFloat) {
      isConfiguringContent = true
      defer { isConfiguringContent = false }

      let clampedWidth = max(1, maxWidth)
      let horizontalInsets = ConversationLayout.railHorizontalInset
      let maxConversationRailWidth = ConversationLayout.railMaxWidth
      let innerWidth = max(1, clampedWidth - (horizontalInsets * 2))
      let railWidth = min(innerWidth, maxConversationRailWidth)
      let constrainedContent = AnyView(
        content
          .frame(maxWidth: railWidth, alignment: .leading)
          .frame(maxWidth: innerWidth, alignment: .center)
          .padding(.horizontal, horizontalInsets)
          .frame(maxWidth: clampedWidth, alignment: .center)
          .fixedSize(horizontal: false, vertical: true)
      )
      if let hostingView {
        hostingView.rootView = constrainedContent
        hostingView.invalidateIntrinsicContentSize()
        hostingView.layoutSubtreeIfNeeded()
        hostingView.resetObservedHeight()
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
      } else {
        let hostingView = LayoutObservingHostingView(rootView: constrainedContent)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.onIntrinsicContentSizeInvalidated = { [weak self] height in
          guard let self else { return }
          guard !self.isConfiguringContent, !self.isMeasuringHeight else { return }
          self.onContentHeightDidChange?(height)
        }
        addSubview(hostingView)
        NSLayoutConstraint.activate([
          hostingView.topAnchor.constraint(equalTo: topAnchor),
          hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
          hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
          hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        hostingView.layoutSubtreeIfNeeded()
        hostingView.resetObservedHeight()
        self.hostingView = hostingView
      }
    }

    func requiredHeight(for width: CGFloat) -> CGFloat {
      guard width > 1 else { return 1 }
      isMeasuringHeight = true
      defer { isMeasuringHeight = false }

      // Reset both frames to a clean baseline so previous row's dimensions
      // don't pollute fittingSize/intrinsicContentSize of the current row.
      let baseline = NSRect(x: 0, y: 0, width: width, height: 1)
      frame = baseline
      guard let hostingView else { return 1 }
      hostingView.frame = baseline

      hostingView.invalidateIntrinsicContentSize()
      hostingView.layoutSubtreeIfNeeded()

      let intrinsic = hostingView.intrinsicContentSize
      let fitting = hostingView.fittingSize

      // Prefer intrinsicContentSize — it reflects what SwiftUI actually needs.
      // fittingSize can be polluted by the hosting view's current frame height.
      let height: CGFloat = if intrinsic.height.isFinite, intrinsic.height > 0,
                               intrinsic.height != NSView.noIntrinsicMetric
      {
        intrinsic.height
      } else {
        fitting.height
      }

      return max(1, height)
    }
  }

  private final class LayoutObservingHostingView: NSHostingView<AnyView> {
    var onIntrinsicContentSizeInvalidated: ((CGFloat) -> Void)?
    private var lastObservedHeight: CGFloat?

    override func invalidateIntrinsicContentSize() {
      super.invalidateIntrinsicContentSize()
      publishObservedHeightIfNeeded()
    }

    override func layout() {
      super.layout()
      publishObservedHeightIfNeeded()
    }

    func resetObservedHeight() {
      lastObservedHeight = nil
    }

    private var measuredIntrinsicHeight: CGFloat {
      let intrinsic = intrinsicContentSize.height
      if intrinsic.isFinite, intrinsic > 0, intrinsic != NSView.noIntrinsicMetric {
        return intrinsic
      }
      return fittingSize.height
    }

    private func publishObservedHeightIfNeeded() {
      let measuredHeight = measuredIntrinsicHeight
      guard measuredHeight.isFinite, measuredHeight > 1 else { return }
      // Skip small deltas to reduce callback churn — the engine-level
      // oscillation guard handles the real protection.
      if let previous = lastObservedHeight, abs(previous - measuredHeight) < 4.0 {
        return
      }
      lastObservedHeight = measuredHeight
      onIntrinsicContentSizeInvalidated?(measuredHeight)
    }
  }

  private final class ClearTableRowView: NSTableRowView {
    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      wantsLayer = true
      layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
      super.init(coder: coder)
      wantsLayer = true
      layer?.masksToBounds = true
    }

    override var isOpaque: Bool {
      false
    }

    override var wantsUpdateLayer: Bool {
      true
    }

    override func updateLayer() {
      layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func drawSelection(in dirtyRect: NSRect) {}
  }

  /// NSTableView subclass that clamps its frame width to the enclosing clip view.
  /// NSTableView internally recomputes its frame from column metrics in `tile()`,
  /// which can make it wider than the scroll view. This override prevents that.
  private final class WidthClampedTableView: NSTableView {
    override func tile() {
      super.tile()
      if let clipWidth = enclosingScrollView?.contentView.bounds.width,
         frame.width != clipWidth
      {
        frame.size.width = clipWidth
      }
    }
  }

  private final class VerticalOnlyClipView: NSClipView {
    override var isFlipped: Bool {
      true
    }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
      var constrained = super.constrainBoundsRect(proposedBounds)
      constrained.origin.x = 0
      return constrained
    }
  }

#endif

// MARK: - Timeline File Logger

/// Lightweight file logger for conversation timeline debugging.
/// macOS: ~/.orbitdock/logs/timeline.log
/// iOS:   ~/.orbitdock/logs/timeline-ios.log
final class TimelineFileLogger: @unchecked Sendable {
  static let shared = TimelineFileLogger()

  private let fileHandle: FileHandle?
  private let queue = DispatchQueue(label: "com.orbitdock.timeline-logger", qos: .utility)
  private let dateFormatter: DateFormatter

  private init() {
    let logDir = PlatformPaths.orbitDockLogsDirectory
    #if os(iOS)
      let logPath = logDir.appendingPathComponent("timeline-ios.log").path
    #else
      let logPath = logDir.appendingPathComponent("timeline.log").path
    #endif

    dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "HH:mm:ss.SSS"

    try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

    FileManager.default.createFile(atPath: logPath, contents: nil)
    fileHandle = FileHandle(forWritingAtPath: logPath)
    fileHandle?.truncateFile(atOffset: 0)

    write("--- timeline logger started ---")
  }

  deinit {
    try? fileHandle?.close()
  }

  nonisolated func debug(_ message: @autoclosure () -> String) {
    let msg = message()
    queue.async { [weak self] in
      self?.write(msg)
    }
  }

  nonisolated func info(_ message: @autoclosure () -> String) {
    let msg = message()
    queue.async { [weak self] in
      self?.write("ℹ️ \(msg)")
    }
  }

  private func write(_ message: String) {
    let timestamp = dateFormatter.string(from: Date())
    let line = "\(timestamp) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    fileHandle?.seekToEndOfFile()
    fileHandle?.write(data)
  }
}

// MARK: - View Extension for Optional Environment

extension View {
  @ViewBuilder
  func ifLet<T>(_ value: T?, transform: (Self, T) -> some View) -> some View {
    if let value {
      transform(self, value)
    } else {
      self
    }
  }
}
