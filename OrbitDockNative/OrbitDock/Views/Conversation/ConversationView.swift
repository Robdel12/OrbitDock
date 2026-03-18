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
  var displayStatus: SessionDisplayStatus = .ended
  var currentTool: String?
  var pendingToolName: String?
  var pendingPermissionDetail: String?
  var provider: Provider = .claude
  var model: String?
  var selectedWorkerID: String?
  var chatViewMode: ChatViewMode = .focused
  var onNavigateToReviewFile: ((String, Int) -> Void)?
  var onOpenPendingApprovalPanel: (() -> Void)?
  @Binding var jumpToMessageTarget: ConversationJumpTarget?

  @Environment(SessionStore.self) private var serverState

  @Binding var isPinned: Bool
  @Binding var unreadCount: Int
  @Binding var scrollToBottomTrigger: Int

  /// Once the conversation has been rendered, don't flash the loading
  /// skeleton again (e.g. when the store is cleared on navigate-away).
  @State private var hasShownContent = false

  private let pageSize = 50

  private var conversationStore: ConversationStore? {
    guard let sessionId else { return nil }
    return serverState.conversation(sessionId)
  }

  private var loadState: ConversationLoadState {
    guard let store = conversationStore else { return .empty }
    if !store.rowEntries.isEmpty { return .ready }
    // If we already rendered content, the store was cleared (e.g. on
    // unsubscribe). Show nothing instead of re-showing the skeleton.
    if hasShownContent { return .empty }
    switch store.state {
      case .idle, .loading: return .loading
      case .ready: return .empty
      case .failed: return .empty
    }
  }

  var body: some View {
    ZStack {
      Color.backgroundPrimary
        .ignoresSafeArea()

      switch loadState {
        case .loading:
          ConversationLoadingView()
            .transition(.opacity)
        case .empty:
          ConversationEmptyStateView()
            .transition(.opacity)
        case .ready:
          VStack(spacing: 0) {
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

            ZStack(alignment: .bottomTrailing) {
              conversationTimeline

              if !isPinned {
                ConversationFollowPill(
                  unreadCount: unreadCount,
                  onTap: {
                    isPinned = true
                    unreadCount = 0
                    scrollToBottomTrigger += 1
                  }
                )
                .padding(.trailing, Spacing.lg)
                .padding(.bottom, Spacing.sm)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(Motion.standard, value: isPinned)
              }
            }

            if isSessionActive || displayStatus == .ended {
              OrbitStatusIndicator(
                displayStatus: displayStatus,
                currentTool: currentTool
              )
            }
          }
          .transition(.opacity)
      }
    }
    .animation(Motion.fade, value: loadState == .loading)
    .onChange(of: loadState) { _, newState in
      if newState == .ready { hasShownContent = true }
    }
    .onChange(of: conversationStore?.rowEntries.count ?? 0) { oldCount, newCount in
      guard !isPinned, newCount > oldCount else { return }
      unreadCount += newCount - oldCount
    }
  }

  // MARK: - Timeline

  @ViewBuilder
  private var conversationTimeline: some View {
    if let conversationStore, let sessionId {
      TimelineScrollView(
        entries: conversationStore.rowEntries,
        sessionId: sessionId,
        clients: conversationStore.serverClients,
        viewMode: chatViewMode,
        onLoadMore: {
          serverState.loadOlderMessages(sessionId: sessionId, limit: pageSize)
        },
        isPinned: $isPinned,
        scrollToBottomTrigger: $scrollToBottomTrigger
      )
    } else {
      ConversationEmptyStateView()
    }
  }
}

/// Internal to ConversationView — declared at file scope for Equatable conformance
enum ConversationLoadState: Equatable {
  case loading, empty, ready
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
    displayStatus: .working,
    currentTool: "Edit",
    provider: .claude,
    model: "claude-opus-4-6",
    jumpToMessageTarget: $jumpTarget,
    isPinned: $isPinned,
    unreadCount: $unreadCount,
    scrollToBottomTrigger: $scrollTrigger
  )
  .environment(SessionStore.preview())
  .frame(width: 700, height: 600)
  .background(Color.backgroundPrimary)
}
