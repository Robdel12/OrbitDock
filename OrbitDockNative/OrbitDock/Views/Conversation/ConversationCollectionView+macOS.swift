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
    let messagesRevision: Int
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
      return vc
    }

    func updateNSViewController(_ vc: ConversationCollectionViewController, context: Context) {
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

      let oldMode = vc.sourceState.metadata.chatViewMode
      let oldMessageCount = vc.sourceState.messages.count
      let oldMessagesRevision = vc.messagesRevision

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
      vc.messagesRevision = messagesRevision

      // Defer snapshot work to avoid "modifying state during view update"
      let modeChanged = oldMode != chatViewMode
      let revisionChanged = oldMessagesRevision != messagesRevision
      let msgCount = messages.count
      let needsScroll = context.coordinator.lastScrollToBottomTrigger != scrollToBottomTrigger
      let selectedWorkerChanged = oldSelectedWorkerID != selectedWorkerID
      if needsScroll {
        context.coordinator.lastScrollToBottomTrigger = scrollToBottomTrigger
      }
      Task { @MainActor in
        if modeChanged {
          vc.rebuildSnapshot(animated: false)
        } else if revisionChanged || oldMessageCount != msgCount || selectedWorkerChanged {
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
    var focusWorkerInDeck: ((String) -> Void)?
    var selectedWorkerID: String?
    var provider: Provider = .claude
    var model: String?
    var sessionId: String?
    var onLoadMore: (() -> Void)?
    var onNavigateToReviewFile: ((String, Int) -> Void)?
    var onOpenPendingApprovalPanel: (() -> Void)?
    var isPinnedToBottom = true
    var messagesRevision = 0

    // Derived caches for O(1) cell rendering lookups
    var messagesByID: [String: TranscriptMessage] = [:]
    var turnsByID: [String: TurnSummary] = [:]

    var programmaticScrollInProgress = false
    var pendingPinnedScroll = false
    var isNormalizingHorizontalOffset = false
    var isLoadingMoreAtTop = false
    var loadMoreBaselineMessageCount = 0
    var lastKnownWidth: CGFloat = 0

    var tableView: NSTableView!
    var scrollView: NSScrollView!
    var tableColumn: NSTableColumn!
    var sourceState = ConversationSourceState()
    var uiState = ConversationUIState()
    var projectionResult = ProjectionResult.empty
    var currentRows: [TimelineRow] = []
    var rowIndexByTimelineRowID: [TimelineRowID: Int] = [:]
    let heightEngine = ConversationHeightEngine()
    let signposter = OSSignposter(
      subsystem: Bundle.main.bundleIdentifier ?? "OrbitDock",
      category: "conversation-timeline"
    )
    let logger = TimelineFileLogger.shared
    var needsInitialScroll = true
    /// Tracks which thinking message IDs have been expanded by the user.
    var expandedThinkingIDs: Set<String> = []
    var imageCacheObserver: NSObjectProtocol?

    override func loadView() {
      view = NSView()
      view.wantsLayer = true
      view.layer?.backgroundColor = ConversationLayout.backgroundPrimary.cgColor
    }

    var rowContext: AppKitConversationRowContext {
      let subagentsByID = Dictionary(
        uniqueKeysWithValues: serverState?.session(sessionId ?? "").subagents.map { ($0.id, $0) } ?? []
      )
      return AppKitConversationRowContext(
        rows: currentRows,
        messagesByID: messagesByID,
        turnsByID: turnsByID,
        subagentsByID: subagentsByID,
        metadata: sourceState.metadata,
        uiState: uiState,
        selectedWorkerID: selectedWorkerID,
        approvalCardModel: buildApprovalCardModel(),
        expandedThinkingIDs: expandedThinkingIDs,
        rowWidth: availableRowWidth,
        tableWidth: tableView?.bounds.width ?? 0
      )
    }

    var rowHandlers: AppKitConversationRowHandlers {
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
        focusWorkerInDeck: { [weak self] workerID in
          self?.focusWorkerInDeck?(workerID)
        },
        loadMore: onLoadMore,
        openPendingApprovalPanel: onOpenPendingApprovalPanel
      )
    }

    deinit {
      if let imageCacheObserver {
        NotificationCenter.default.removeObserver(imageCacheObserver)
      }
      NotificationCenter.default.removeObserver(self)
    }
  }

#endif
