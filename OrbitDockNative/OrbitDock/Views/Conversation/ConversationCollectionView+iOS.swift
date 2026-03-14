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
    let messagesRevision: Int
    let streamingPatchRevision: Int
    let latestStreamingPatch: ConversationStreamingPatch?
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
    let selectedWorkerID: String?
    let openFileInReview: ((String) -> Void)?
    let focusWorkerInDeck: ((String) -> Void)?
    let onLoadMore: () -> Void
    let onNavigateToReviewFile: ((String, Int) -> Void)?
    let onOpenPendingApprovalPanel: (() -> Void)?
    @Binding var jumpToMessageTarget: ConversationJumpTarget?

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
      vc.focusWorkerInDeck = focusWorkerInDeck
      vc.selectedWorkerID = selectedWorkerID
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
      vc.streamingPatchRevision = streamingPatchRevision
      return vc
    }

    func updateUIViewController(_ vc: ConversationCollectionViewController, context: Context) {
      vc.coordinator = context.coordinator
      vc.serverState = serverState
      vc.openFileInReview = openFileInReview
      vc.focusWorkerInDeck = focusWorkerInDeck
      let oldSelectedWorkerID = vc.selectedWorkerID
      vc.selectedWorkerID = selectedWorkerID
      vc.provider = provider
      vc.model = model
      vc.sessionId = sessionId
      vc.onLoadMore = onLoadMore
      vc.onNavigateToReviewFile = onNavigateToReviewFile
      vc.onOpenPendingApprovalPanel = onOpenPendingApprovalPanel

      let oldMode = vc.currentChatViewMode
      let oldMessagesRevision = vc.messagesRevision
      let oldStreamingPatchRevision = vc.streamingPatchRevision
      let oldMessageCount = vc.currentMessageCount

      // Defer snapshot work to avoid "modifying state during view update"
      // — snapshot application triggers UIKit layout which can read back into SwiftUI bindings.
      let modeChanged = oldMode != chatViewMode
      let revisionChanged = oldMessagesRevision != messagesRevision
      let selectedWorkerChanged = oldSelectedWorkerID != selectedWorkerID
      let streamingPatchChanged = oldStreamingPatchRevision != streamingPatchRevision
      let messageCountChanged = oldMessageCount != messages.count
      let needsStructureHydration = modeChanged || revisionChanged || messageCountChanged
      let canApplyStreamingPatch = !modeChanged
        && !revisionChanged
        && !messageCountChanged
        && !selectedWorkerChanged
        && streamingPatchChanged
        && latestStreamingPatch != nil
      let needsScroll = context.coordinator.lastScrollToBottomTrigger != scrollToBottomTrigger
      let jumpTargetChanged = context.coordinator.lastJumpTarget != jumpToMessageTarget
      if canApplyStreamingPatch, let latestStreamingPatch {
        vc.applySessionMetadata(
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
        vc.applyStreamingPatch(latestStreamingPatch, messages: messages)
      } else {
        if needsStructureHydration {
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
        } else {
          vc.forceMetadataReconfigure = true
          vc.applySessionMetadata(
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
        }
      }
      vc.messagesRevision = messagesRevision
      vc.streamingPatchRevision = streamingPatchRevision
      if needsScroll {
        context.coordinator.lastScrollToBottomTrigger = scrollToBottomTrigger
      }
      if jumpTargetChanged {
        context.coordinator.lastJumpTarget = jumpToMessageTarget
      }
      Task { @MainActor in
        if modeChanged {
          vc.rebuildSnapshot(animated: false)
        } else if revisionChanged
          || messageCountChanged
          || selectedWorkerChanged
          || (!needsStructureHydration && !canApplyStreamingPatch)
        {
          vc.applyProjectionUpdate()
        } else if canApplyStreamingPatch {
          // Content-only streaming patch already updated the visible row in place.
        }
        if needsScroll {
          vc.isPinnedToBottom = true
          vc.scrollToBottom(animated: true)
        } else if jumpTargetChanged, let target = jumpToMessageTarget {
          vc.isPinnedToBottom = false
          vc.scrollToConversationMessage(target.messageID, animated: true)
        }
      }
    }

    class Coordinator {
      var parent: ConversationCollectionView
      var lastScrollToBottomTrigger: Int
      var lastJumpTarget: ConversationJumpTarget?

      init(parent: ConversationCollectionView) {
        self.parent = parent
        lastScrollToBottomTrigger = parent.scrollToBottomTrigger
        lastJumpTarget = parent.jumpToMessageTarget
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
    static func formatWidth(_ value: CGFloat) -> String {
      String(format: "%.1f", value)
    }

    var coordinator: ConversationCollectionView.Coordinator?
    var serverState: SessionStore?
    var openFileInReview: ((String) -> Void)?
    var focusWorkerInDeck: ((String) -> Void)?
    var selectedWorkerID: String?
    var provider: Provider = .claude
    var model: String?
    var sessionId: String?
    var onLoadMore: (() -> Void)?
    var onNavigateToReviewFile: ((String, Int) -> Void)?
    var onOpenPendingApprovalPanel: (() -> Void)?
    var isPinnedToBottom = true

    // Timeline state
    var messagesByID: [String: TranscriptMessage] = [:]
    var runtime: ConversationDetailRuntime?
    var currentRows: [TimelineRow] = []
    var rowIndexByTimelineRowID: [TimelineRowID: Int] = [:]
    var previousMessageCount = 0
    var messagesRevision = 0
    var streamingPatchRevision = 0
    var currentChatViewMode: ChatViewMode = .focused
    var currentMessageCount = 0
    var currentRemainingLoadCount = 0
    var currentHasMoreMessages = false
    var supportsRichToolingCards = false
    var expandedToolCardIDs: Set<String> = []
    var expandedActivityGroupIDs: Set<String> = []

    var collectionView: UICollectionView!
    var dataSource: UICollectionViewDiffableDataSource<ConversationSection, TimelineRowID>!

    // Cell registrations
    var messageCellReg: UICollectionView.CellRegistration<UIKitRichMessageCell, String>!
    var toolStripCellReg: UICollectionView.CellRegistration<UIKitToolStripCell, String>!
    var expandedToolCellReg: UICollectionView.CellRegistration<UIKitExpandedToolCell, String>!
    var loadMoreCellReg: UICollectionView.CellRegistration<UIKitLoadMoreCell, Void>!
    var liveIndicatorCellReg: UICollectionView.CellRegistration<UIKitLiveIndicatorCell, Void>!
    var workerEventCellReg: UICollectionView.CellRegistration<UIKitToolStripCell, String>!
    var workerOrchestrationCellReg: UICollectionView.CellRegistration<UIKitWorkerOrchestrationCell, String>!
    var activitySummaryCellReg: UICollectionView.CellRegistration<UIKitActivitySummaryCell, String>!
    var approvalCardCellReg: UICollectionView.CellRegistration<UIKitApprovalCardCell, Void>!
    var spacerCellReg: UICollectionView.CellRegistration<UIKitSpacerCell, Void>!

    private var needsInitialScroll = true
    var forceMetadataReconfigure = false
    var expandedThinkingIDs: Set<String> = []
    /// Cached heights keyed by TimelineRowID. Invalidated on width change.
    var heightCache: [TimelineRowID: CGFloat] = [:]
    private var lastLayoutWidth: CGFloat = 0
    let logger = TimelineFileLogger.shared

    private var scopedSessionID: ScopedSessionID? {
      guard let sessionId, let endpointId = serverState?.endpointId else { return nil }
      return ScopedSessionID(endpointId: endpointId, sessionId: sessionId)
    }

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
        heightCache.removeAll()
        collectionView.collectionViewLayout.invalidateLayout()
      }

      if needsInitialScroll, currentMessageCount > 0 {
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

    func applySessionMetadata(
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
      let observable = sessionId.flatMap { serverState?.session($0) }
      let resolvedApprovalId = observable?.pendingApprovalId
      currentChatViewMode = chatViewMode
      currentRemainingLoadCount = remainingLoadCount
      currentHasMoreMessages = hasMoreMessages
      supportsRichToolingCards = observable?.isDirect ?? false

      ensureRuntime()
      runtime?.hydrateMetadata(
        ConversationMetadataInput(
          isSessionActive: isSessionActive,
          workStatus: workStatus,
          currentTool: observable?.lastTool ?? currentTool,
          pendingToolName: observable?.pendingToolName ?? pendingToolName,
          pendingPermissionDetail: observable?.pendingPermissionDetail ?? pendingPermissionDetail,
          currentPrompt: currentPrompt,
          approval: observable?.pendingApproval,
          pendingApprovalId: resolvedApprovalId,
          approvalVersion: observable?.approvalVersion,
          pendingQuestion: observable?.pendingQuestion,
          workers: observable?.subagents ?? [],
          selectedWorkerID: selectedWorkerID,
          toolsByWorker: observable?.subagentTools ?? [:],
          messagesByWorker: observable?.subagentMessages ?? [:],
          tokenUsage: observable?.tokenUsage,
          tokenUsageSnapshotKind: observable?.tokenUsageSnapshotKind,
          provider: provider,
          model: model
        )
      )
    }

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
      messagesByID = Dictionary(uniqueKeysWithValues: resolvedMessages.map { ($0.id, $0) })
      currentMessageCount = resolvedMessages.count
      previousMessageCount = resolvedMessages.count

      ensureRuntime()
      runtime?.hydrateStructure(
        messages: resolvedMessages,
        oldestLoadedSequence: resolvedMessages.first?.sequence,
        newestLoadedSequence: resolvedMessages.last?.sequence,
        hasMoreHistoryBefore: hasMoreMessages
      )

      applySessionMetadata(
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
    }

    func applyStreamingPatch(_ patch: ConversationStreamingPatch, messages: [TranscriptMessage]) {
      guard let incoming = messages.first(where: { $0.id == patch.messageId }),
            let previousMessage = messagesByID[patch.messageId]
      else {
        return
      }
      messagesByID[patch.messageId] = incoming

      if incoming.isInProgress {
        runtime?.applyStreaming(.replace(
          messageID: incoming.id,
          content: incoming.content,
          invalidatesHeight: shouldInvalidateStreamingHeight(previous: previousMessage, next: incoming)
        ))
      } else {
        runtime?.applyStreaming(.finalize(
          messageID: incoming.id,
          content: incoming.content,
          invalidatesHeight: true
        ))
      }

      guard let rowIndex = currentRows.firstIndex(where: { row in
        if case let .message(id, _) = row.payload {
          return id == patch.messageId
        }
        return false
      }) else {
        return
      }

      let timelineRow = currentRows[rowIndex]
      guard let model = buildRichMessageModel(for: timelineRow) else {
        applyProjectionUpdate()
        return
      }

      let indexPath = IndexPath(item: rowIndex, section: 0)
      let rowID = currentRows[rowIndex].id

      if let richCell = collectionView.cellForItem(at: indexPath) as? UIKitRichMessageCell,
         richCell.applyStreamingUpdate(model: model, width: collectionView.bounds.width)
      {
        if shouldInvalidateStreamingHeight(previous: previousMessage, next: incoming) {
          heightCache[rowID] = UIKitRichMessageCell.requiredHeight(for: collectionView.bounds.width, model: model)
          collectionView.collectionViewLayout.invalidateLayout()
        }
      } else {
        heightCache.removeValue(forKey: rowID)
        applyProjectionUpdate()
      }
    }

    private func shouldInvalidateStreamingHeight(previous: TranscriptMessage, next: TranscriptMessage) -> Bool {
      let previousNewlines = previous.content.reduce(into: 0) { count, character in
        if character == "\n" { count += 1 }
      }
      let nextNewlines = next.content.reduce(into: 0) { count, character in
        if character == "\n" { count += 1 }
      }
      if previousNewlines != nextNewlines {
        return true
      }

      let previousBucket = previous.content.count / 96
      let nextBucket = next.content.count / 96
      return previousBucket != nextBucket
    }

    func rebuildSnapshot(animated: Bool = false) {
      guard dataSource != nil else { return }
      currentRows = buildTimelineRows()
      rebuildRowLookup()

      logger.info(
        "rebuildSnapshot rows=\(currentRows.count) msgs=\(currentMessageCount) "
          + "mode=\(currentChatViewMode) "
          + "w=\(Self.formatWidth(collectionView.bounds.width))"
      )

      heightCache.removeAll()
      var snapshot = NSDiffableDataSourceSnapshot<ConversationSection, TimelineRowID>()
      snapshot.appendSections([.main])
      snapshot.appendItems(currentRows.map(\.id))
      dataSource.apply(snapshot, animatingDifferences: animated)
    }

    func applyProjectionUpdate() {
      guard dataSource != nil else { return }
      let oldIDs = currentRows.map(\.id)
      let oldRows = currentRows
      let newRows = buildTimelineRows()
      let newIDs = newRows.map(\.id)
      let structureChanged = oldIDs != newIDs

      // Capture scroll anchor before applying changes when not pinned to bottom
      let isPrepend = !isPinnedToBottom
        && ConversationScrollAnchorMath.isPrependTransition(from: oldIDs, to: newIDs)
      var savedAnchor: (rowID: TimelineRowID, delta: Double)?
      if isPrepend {
        savedAnchor = captureTopVisibleAnchor()
      }

      if structureChanged {
        currentRows = newRows
        rebuildRowLookup()
        heightCache.removeAll()
        var snapshot = NSDiffableDataSourceSnapshot<ConversationSection, TimelineRowID>()
        snapshot.appendSections([.main])
        snapshot.appendItems(currentRows.map(\.id))
        dataSource.apply(snapshot, animatingDifferences: false)
        forceMetadataReconfigure = false
      } else {
        currentRows = newRows
        rebuildRowLookup()

        var reconfigureIDs: [TimelineRowID] = forceMetadataReconfigure ? newRows.map(\.id) : []
        for (index, row) in newRows.enumerated() where index < oldRows.count {
          guard oldRows[index] != row else { continue }
          heightCache.removeValue(forKey: row.id)
          reconfigureIDs.append(row.id)
        }

        if !reconfigureIDs.isEmpty {
          var snapshot = dataSource.snapshot()
          snapshot.reconfigureItems(reconfigureIDs)
          dataSource.apply(snapshot, animatingDifferences: false)
          // Heights may have changed — force layout to re-query sizeForItemAt
          collectionView.collectionViewLayout.invalidateLayout()
        }
        forceMetadataReconfigure = false
      }

      // Restore scroll anchor after prepend
      if let anchor = savedAnchor {
        restoreScrollAnchor(anchor)
      } else if isPinnedToBottom {
        scrollToBottom(animated: false)
      } else if currentMessageCount > previousMessageCount {
        let delta = currentMessageCount - previousMessageCount
        coordinator?.unreadDelta(delta)
      }
      previousMessageCount = currentMessageCount
    }

    private func rebuildRowLookup() {
      rowIndexByTimelineRowID.removeAll(keepingCapacity: true)
      for (index, row) in currentRows.enumerated() {
        rowIndexByTimelineRowID[row.id] = index
      }
    }

    private func buildTimelineRows() -> [TimelineRow] {
      guard let runtime else { return [] }
      return IOSTimelineBuilder.build(
        renderStore: runtime.renderStore,
        messagesByID: messagesByID,
        hasMoreMessages: currentHasMoreMessages,
        chatViewMode: currentChatViewMode,
        expansionState: .init(expandedActivityGroupIDs: expandedActivityGroupIDs)
      )
    }

    private func ensureRuntime() {
      guard let scopedSessionID, let serverState, let sessionId else {
        runtime = nil
        return
      }

      if runtime?.session != scopedSessionID {
        runtime = ConversationDetailRuntime(
          session: scopedSessionID,
          clients: serverState.conversation(sessionId).serverClients,
          provider: provider,
          model: model
        )
      }
    }
  }

#endif
