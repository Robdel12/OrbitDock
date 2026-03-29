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
  var showsOrbitStatusIndicator: Bool = true
  var chatViewMode: ChatViewMode = .focused
  @Binding var scrollCommand: ConversationScrollCommand?

  let onJumpToLatest: () -> Void
  let onFollowStateChanged: (ConversationFollowState) -> Void
  @State private var viewModel = ConversationViewModel()
  @State private var localFollowState = ConversationFollowState.initial

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

              if !localFollowState.mode.isFollowing {
                ConversationFollowPill(
                  unreadCount: localFollowState.unreadCount,
                  onTap: onJumpToLatest
                )
                .padding(.trailing, Spacing.lg)
                .padding(.bottom, Spacing.sm)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(Motion.standard, value: localFollowState.mode)
              }
            }

            if showsOrbitStatusIndicator && (isSessionActive || displayStatus == .ended) {
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
      localFollowState = .initial
      viewModel.bind(sessionId: sessionId, sessionStore: sessionStore, viewMode: chatViewMode)
    }
    .animation(Motion.fade, value: viewModel.loadState == .loading)
    .onChange(of: viewModel.loadState) { _, newState in
      viewModel.handleLoadStateChange(newState)
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
        scrollCommand: $scrollCommand,
        onLoadMore: {
          viewModel.loadOlderMessages()
        },
        latestAppendEvent: viewModel.latestAppendEvent,
        onFollowStateChanged: { state in
          localFollowState = state
          onFollowStateChanged(state)
        }
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
  @Previewable @State var scrollCommand: ConversationScrollCommand?

  ConversationView(
    sessionId: nil,
    sessionStore: SessionStore.preview(),
    isSessionActive: true,
    displayStatus: .working,
    currentTool: "Edit",
    scrollCommand: $scrollCommand,
    onJumpToLatest: {
      // In real usage, the parent emits a .jumpToLatest scroll command
    },
    onFollowStateChanged: { state in
      print("Follow state: \(state.mode.rawValue) unread: \(state.unreadCount)")
    }
  )
  .frame(width: 700, height: 600)
  .background(Color.backgroundPrimary)
}
