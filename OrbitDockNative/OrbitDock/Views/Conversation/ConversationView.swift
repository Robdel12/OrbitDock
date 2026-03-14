//
//  ConversationView.swift
//  OrbitDock
//

import SwiftUI

struct ConversationView: View {
  let sessionId: String?
  var endpointId: UUID?
  var isSessionActive: Bool = false
  var workStatus: Session.WorkStatus = .unknown
  var currentTool: String?
  var pendingToolName: String?
  var pendingPermissionDetail: String?
  var provider: Provider = .claude
  var model: String?
  var selectedWorkerID: String? = nil
  var chatViewMode: ChatViewMode = .focused
  var onNavigateToReviewFile: ((String, Int) -> Void)? // (filePath, lineNumber) deep link from review card
  var onOpenPendingApprovalPanel: (() -> Void)?
  @Binding var jumpToMessageTarget: ConversationJumpTarget?

  @Environment(SessionStore.self) private var serverState

  @State private var currentPrompt: String?
  @State private var loadedSessionId: String?

  // Auto-follow state - controlled by parent
  @Binding var isPinned: Bool
  @Binding var unreadCount: Int
  @Binding var scrollToBottomTrigger: Int

  private let pageSize = 50

  private var obs: SessionObservable {
    serverState.session(sessionId ?? "")
  }

  private var conversationStore: ConversationStore? {
    guard let sessionId else { return nil }
    return serverState.conversation(sessionId)
  }

  private var displayedMessages: [TranscriptMessage] {
    conversationStore?.normalizedMessages ?? []
  }

  private var messagesRevision: Int {
    conversationStore?.messagesRevision ?? 0
  }

  private var streamingPatchRevision: Int {
    conversationStore?.streamingPatchRevision ?? 0
  }

  private var latestStreamingPatch: ConversationStreamingPatch? {
    conversationStore?.latestStreamingPatch
  }

  private var viewState: ConversationViewState {
    guard let conversationStore else {
      return ConversationViewState(
        loadState: .empty,
        hasMoreMessages: false,
        remainingLoadCount: 0,
        totalMessageCount: displayedMessages.count
      )
    }

    return ConversationViewState.derive(
      messageCount: displayedMessages.count,
      totalMessageCount: conversationStore.totalMessageCount,
      hasRenderableConversation: conversationStore.hasRenderableConversation,
      hydrationState: conversationStore.hydrationState,
      hasMoreHistoryBefore: conversationStore.hasMoreHistoryBefore,
      pageSize: pageSize
    )
  }

  var hasMoreMessages: Bool {
    viewState.hasMoreMessages
  }

  var remainingLoadCount: Int {
    viewState.remainingLoadCount
  }

  private var totalMessageCount: Int {
    viewState.totalMessageCount
  }

  var body: some View {
    ZStack {
      // Background
      Color.backgroundPrimary
        .ignoresSafeArea()

      switch viewState.loadState {
        case .loading:
          ConversationLoadingView()
            .transition(.opacity)
        case .empty:
          ConversationEmptyStateView()
            .transition(.opacity)
            .onAppear {
              print("why")
            }
        case .ready:
          VStack(spacing: 0) {
            // Fork origin banner (persistent, above scroll)
            if let sid = sessionId, let sourceId = serverState.session(sid).forkedFrom {
              ConversationForkOriginBanner(
                sourceSessionId: sourceId,
                sourceEndpointId: endpointId,
                sourceName: serverState.session(sourceId).displayName
              )
              .padding(.horizontal, Spacing.lg)
              .padding(.top, Spacing.sm)
              .padding(.bottom, Spacing.xs)
            }

            conversationThread
          }
          .transition(.opacity)
      }
    }
    .animation(Motion.fade, value: viewState.loadState == .loading)
    .animation(Motion.fade, value: displayedMessages.isEmpty)
    .onChange(of: sessionId) { _, newId in
      loadedSessionId = newId
      currentPrompt = nil
    }
    .onAppear {
      print("why lol")
    }
  }

  // MARK: - Main Thread View

  @Environment(\.openFileInReview) private var openFileInReview
  @Environment(\.focusWorkerInDeck) private var focusWorkerInDeck

  @ViewBuilder
  private var conversationThread: some View {
    #if os(macOS)
      if let conversationStore, let sessionId, let endpointId {
        ConversationMacDetailView(
          session: ScopedSessionID(endpointId: endpointId, sessionId: sessionId),
          conversationStore: conversationStore,
          obs: obs,
          provider: provider,
          model: model,
          currentTool: currentTool,
          pendingToolName: pendingToolName,
          pendingPermissionDetail: pendingPermissionDetail,
          currentPrompt: currentPrompt,
          chatViewMode: chatViewMode,
          loadState: viewState.loadState,
          remainingLoadCount: remainingLoadCount,
          isPinnedToBottom: isPinned,
          unreadCount: unreadCount,
          selectedWorkerID: selectedWorkerID,
          focusWorkerInDeck: focusWorkerInDeck,
          onLoadMore: {
            serverState.loadOlderMessages(sessionId: sessionId, limit: pageSize)
          }
        )
      } else {
        MacTimelineView(
          viewState: MacTimelineViewState(
            rows: [
              .utility(
                .init(
                  id: "utility:empty",
                  kind: .live,
                  iconName: "bubble.left.and.text.bubble.right",
                  eyebrow: "Timeline",
                  title: "No conversation yet",
                  subtitle: nil,
                  spotlight: nil,
                  trailingBadge: nil,
                  accentColorName: "reply",
                  chips: [],
                  activityAnchorID: nil,
                  isExpanded: false
                )
              )
            ],
            isPinnedToBottom: isPinned,
            unreadCount: unreadCount
          ),
          onLoadMore: nil,
          onToggleToolExpansion: nil,
          onToggleActivityExpansion: nil,
          onFocusWorker: nil
        )
      }
    #else
      ConversationCollectionView(
        messages: displayedMessages,
        messagesRevision: messagesRevision,
        streamingPatchRevision: streamingPatchRevision,
        latestStreamingPatch: latestStreamingPatch,
        chatViewMode: chatViewMode,
        isSessionActive: isSessionActive,
        workStatus: workStatus,
        currentTool: currentTool,
        pendingToolName: pendingToolName,
        pendingPermissionDetail: pendingPermissionDetail,
        provider: provider,
        model: model,
        sessionId: sessionId,
        serverState: serverState,
        hasMoreMessages: hasMoreMessages,
        currentPrompt: currentPrompt,
        messageCount: totalMessageCount,
        remainingLoadCount: remainingLoadCount,
        selectedWorkerID: selectedWorkerID,
        openFileInReview: openFileInReview,
        focusWorkerInDeck: focusWorkerInDeck,
        onLoadMore: {
          guard let sid = sessionId else { return }
          serverState.loadOlderMessages(sessionId: sid, limit: pageSize)
        },
        onNavigateToReviewFile: onNavigateToReviewFile,
        onOpenPendingApprovalPanel: onOpenPendingApprovalPanel,
        jumpToMessageTarget: $jumpToMessageTarget,
        isPinned: $isPinned,
        unreadCount: $unreadCount,
        scrollToBottomTrigger: $scrollToBottomTrigger
      )
    #endif
  }
}

// MARK: - Preview

#Preview {
  @Previewable @State var isPinned = true
  @Previewable @State var unreadCount = 0
  @Previewable @State var scrollTrigger = 0
  @Previewable @State var jumpTarget: ConversationJumpTarget?

  ConversationView(
    sessionId: nil,
    isSessionActive: true,
    workStatus: .working,
    currentTool: "Edit",
    provider: .claude,
    model: "claude-opus-4-6",
    jumpToMessageTarget: $jumpTarget,
    isPinned: $isPinned,
    unreadCount: $unreadCount,
    scrollToBottomTrigger: $scrollTrigger
  )
  .environment(SessionStore())
  .frame(width: 700, height: 600)
  .background(Color.backgroundPrimary)
}
