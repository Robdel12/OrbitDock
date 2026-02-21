//
//  ConversationCollectionView+iOS.swift
//  OrbitDock
//
//  iOS UICollectionView implementation for the conversation timeline.
//

import OSLog
import SwiftUI

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
              let preview = CompactToolHelpers.diffPreview(for: message)
              height = UIKitCompactToolCell.requiredHeight(
                for: width,
                summary: summary,
                hasDiffPreview: preview != nil,
                hasContextLine: preview?.contextLine != nil
              )
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

#endif
