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

  @Binding var isPinned: Bool
  @Binding var unreadCount: Int
  @Binding var scrollToBottomTrigger: Int
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
    .task(id: "\(sessionStore.endpointId.uuidString):\(sessionId ?? "")") {
      viewModel.bind(sessionId: sessionId, sessionStore: sessionStore)
    }
    .animation(Motion.fade, value: viewModel.loadState == .loading)
    .onChange(of: viewModel.loadState) { _, newState in
      viewModel.handleLoadStateChange(newState)
    }
    .onChange(of: viewModel.entryCount) { oldCount, newCount in
      viewModel.handleEntryCountChange(
        oldCount: oldCount,
        newCount: newCount,
        isPinned: isPinned,
        unreadCount: &unreadCount
      )
    }
  }

  // MARK: - Timeline

  @ViewBuilder
  private var conversationTimeline: some View {
    if let timeline = viewModel.timeline, let sessionId {
      TimelineScrollView(
        entries: timeline.entries,
        contentRevision: timeline.contentRevision,
        structureRevision: timeline.structureRevision,
        changedEntries: timeline.changedEntries,
        sessionId: sessionId,
        clients: sessionStore.clients,
        viewMode: chatViewMode,
        onLoadMore: {
          viewModel.loadOlderMessages()
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
    sessionStore: SessionStore.preview(),
    isSessionActive: true,
    displayStatus: .working,
    currentTool: "Edit",
    jumpToMessageTarget: $jumpTarget,
    isPinned: $isPinned,
    unreadCount: $unreadCount,
    scrollToBottomTrigger: $scrollTrigger
  )
  .frame(width: 700, height: 600)
  .background(Color.backgroundPrimary)
}
