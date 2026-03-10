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

    func updateUIViewController(_ vc: ConversationCollectionViewController, context: Context) {
      vc.coordinator = context.coordinator
      vc.serverState = serverState
      vc.openFileInReview = openFileInReview
      vc.provider = provider
      vc.model = model
      vc.sessionId = sessionId
      vc.onLoadMore = onLoadMore
      vc.onNavigateToReviewFile = onNavigateToReviewFile
      vc.onOpenPendingApprovalPanel = onOpenPendingApprovalPanel

      let oldMode = vc.chatViewMode

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

  class ConversationCollectionViewController: UIViewController {
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

    // Timeline state — mirrors macOS VC pattern
    var sourceState = ConversationSourceState()
    var uiState = ConversationUIState()
    var messagesByID: [String: TranscriptMessage] = [:]
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
    private var liveProgressCellReg: UICollectionView.CellRegistration<UIKitLiveProgressCell, Void>!
    private var approvalCardCellReg: UICollectionView.CellRegistration<UIKitApprovalCardCell, Void>!
    private var collapsedTurnCellReg: UICollectionView.CellRegistration<UIKitCollapsedTurnCell, String>!
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
        source: "timeline-apply-ios"
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

      messagesByID = Dictionary(uniqueKeysWithValues: sourceState.messages.map { ($0.id, $0) })

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

  }

#endif
