//
//  ConversationView.swift
//  OrbitDock
//

import SwiftUI

struct ConversationView: View {
  let sessionId: String?
  let sessionStore: SessionStore
  var endpointId: UUID?
  var isSessionActive: Bool = false
  var displayStatus: SessionDisplayStatus = .ended
  var currentTool: String?
  var chatViewMode: ChatViewMode = .focused
  @Binding var jumpToMessageTarget: ConversationJumpTarget?

  let isPinned: Bool
  let unreadCount: Int
  let scrollToBottomTrigger: Int
  let onJumpToLatest: () -> Void
  let onReachedBottom: () -> Void
  let onLeftBottomByUser: () -> Void
  let onEntryCountChanged: (_ oldCount: Int, _ newCount: Int) -> Void
  @State private var viewModel = ConversationViewModel()

  var body: some View {
    ZStack {
      Color.backgroundPrimary
        .ignoresSafeArea()

      switch viewModel.loadState {
        case .loading:
          ConversationLoadingView()
            .transition(.opacity)
        case .empty:
          ConversationEmptyStateView()
            .transition(.opacity)
        case .ready:
          VStack(spacing: 0) {
            if let forkOrigin = viewModel.forkOrigin {
              ConversationForkOriginBanner(
                sourceSessionId: forkOrigin.sourceSessionId,
                sourceEndpointId: forkOrigin.sourceEndpointId ?? endpointId,
                sourceName: forkOrigin.sourceName
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
                  onTap: onJumpToLatest
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
    .task(id: "\(sessionStore.endpointId.uuidString):\(sessionId ?? "")") {
      viewModel.bind(sessionId: sessionId, sessionStore: sessionStore, viewMode: chatViewMode)
    }
    .animation(Motion.fade, value: viewModel.loadState == .loading)
    .onChange(of: viewModel.loadState) { _, newState in
      viewModel.handleLoadStateChange(newState)
    }
    .onChange(of: viewModel.entryCount) { oldCount, newCount in
      onEntryCountChanged(oldCount, newCount)
    }
    .onChange(of: chatViewMode) { _, newMode in
      viewModel.handleTimelineViewModeChange(newMode)
    }
  }

  // MARK: - Timeline

  @ViewBuilder
  private var conversationTimeline: some View {
    if viewModel.timeline != nil, let sessionId {
      TimelineScrollView(
        viewModel: viewModel.timelineViewModel,
        sessionId: sessionId,
        clients: sessionStore.clients,
        onLoadMore: {
          viewModel.loadOlderMessages()
        },
        isPinned: isPinned,
        scrollToBottomTrigger: scrollToBottomTrigger,
        onReachedBottom: onReachedBottom,
        onLeftBottomByUser: onLeftBottomByUser
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
    sessionStore: SessionStore.preview(),
    isSessionActive: true,
    displayStatus: .working,
    currentTool: "Edit",
    jumpToMessageTarget: $jumpTarget,
    isPinned: isPinned,
    unreadCount: unreadCount,
    scrollToBottomTrigger: scrollTrigger,
    onJumpToLatest: {
      isPinned = true
      unreadCount = 0
      scrollTrigger += 1
    },
    onReachedBottom: {
      isPinned = true
      unreadCount = 0
    },
    onLeftBottomByUser: {
      isPinned = false
    },
    onEntryCountChanged: { oldCount, newCount in
      guard !isPinned, newCount > oldCount else { return }
      unreadCount += newCount - oldCount
    }
  )
  .frame(width: 700, height: 600)
  .background(Color.backgroundPrimary)
}
