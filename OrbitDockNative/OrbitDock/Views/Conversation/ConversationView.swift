//
//  ConversationView.swift
//  OrbitDock
//

import SwiftUI

struct ConversationView: View {
  let sessionId: String?
  let session: ServerSessionContext
  let viewModel: ConversationViewModel
  var endpointId: UUID?
  var isSessionActive: Bool = false
  var displayStatus: SessionDisplayStatus = .ended
  var currentTool: String?
  var showsOrbitStatusIndicator: Bool = true
  var chatViewMode: ChatViewMode = .focused
  @Binding var scrollCommand: ConversationScrollCommand?

  let onJumpToLatest: () -> Void
  let onFollowStateChanged: (ConversationFollowState) -> Void

  init(
    sessionId: String?,
    session: ServerSessionContext,
    viewModel: ConversationViewModel,
    endpointId: UUID? = nil,
    isSessionActive: Bool = false,
    displayStatus: SessionDisplayStatus = .ended,
    currentTool: String? = nil,
    showsOrbitStatusIndicator: Bool = true,
    chatViewMode: ChatViewMode = .focused,
    scrollCommand: Binding<ConversationScrollCommand?>,
    onJumpToLatest: @escaping () -> Void,
    onFollowStateChanged: @escaping (ConversationFollowState) -> Void
  ) {
    self.sessionId = sessionId
    self.session = session
    self.viewModel = viewModel
    self.endpointId = endpointId
    self.isSessionActive = isSessionActive
    self.displayStatus = displayStatus
    self.currentTool = currentTool
    self.showsOrbitStatusIndicator = showsOrbitStatusIndicator
    self.chatViewMode = chatViewMode
    _scrollCommand = scrollCommand
    self.onJumpToLatest = onJumpToLatest
    self.onFollowStateChanged = onFollowStateChanged
  }

  var body: some View {
    ZStack {
      Color.backgroundPrimary
        .ignoresSafeArea()

      content
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
  private var content: some View {
    switch viewModel.loadState {
      case .loading:
        ConversationLoadingView()
          .transition(.opacity)
      case .empty:
        ConversationEmptyStateView()
          .transition(.opacity)
      case .ready:
        loadedConversation
          .transition(.opacity)
    }
  }

  private var loadedConversation: some View {
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

        if !viewModel.followState.mode.isFollowing {
          ConversationFollowPill(
            unreadCount: viewModel.followState.unreadCount,
            onTap: onJumpToLatest
          )
          .padding(.trailing, Spacing.lg)
          .padding(.bottom, Spacing.sm)
          .transition(.move(edge: .bottom).combined(with: .opacity))
          .animation(Motion.standard, value: viewModel.followState.mode)
        }
      }

      if showsOrbitStatusIndicator, (isSessionActive || displayStatus == .ended) {
        OrbitStatusIndicator(
          displayStatus: displayStatus,
          currentTool: currentTool
        )
      }
    }
  }

  @ViewBuilder
  private var conversationTimeline: some View {
    if viewModel.hasTimeline, let sessionId {
      TimelineScrollView(
        viewModel: viewModel.timelineViewModel,
        sessionId: sessionId,
        endpointId: endpointId,
        clients: session.clients,
        scrollCommand: $scrollCommand,
        onLoadMore: {
          viewModel.loadOlderMessages()
        },
        latestAppendEvent: viewModel.latestAppendEvent,
        onFollowStateChanged: { state in
          viewModel.applyFollowState(state)
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
  @Previewable @State var viewModel = ConversationViewModel(
    sessionId: nil,
    session: ServerSessionContext.preview(),
    viewMode: .focused
  )

  ConversationView(
    sessionId: nil,
    session: ServerSessionContext.preview(),
    viewModel: viewModel,
    isSessionActive: true,
    displayStatus: .working,
    currentTool: "Edit",
    scrollCommand: $scrollCommand,
    onJumpToLatest: {
      // In real usage, the parent emits a .jumpToLatest scroll command
    },
    onFollowStateChanged: { _ in }
  )
  .frame(width: 700, height: 600)
  .background(Color.backgroundPrimary)
}
