//
//  ConversationView.swift
//  OrbitDock
//

import SwiftUI

struct ConversationView: View {
  let sessionId: String?
  let session: ServerSessionContext
  var endpointId: UUID?
  var isSessionActive: Bool = false
  var displayStatus: SessionDisplayStatus = .ended
  var currentTool: String?
  var showsOrbitStatusIndicator: Bool = true
  var chatViewMode: ChatViewMode = .focused
  @Binding var scrollCommand: ConversationScrollCommand?

  let onJumpToLatest: () -> Void
  let onFollowStateChanged: (ConversationFollowState) -> Void
  @State private var viewModel: ConversationViewModel
  private var bindingIdentity: String {
    "\(session.endpointId.uuidString):\(sessionId ?? ""):\(ObjectIdentifier(session))"
  }

  init(
    sessionId: String?,
    session: ServerSessionContext,
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
    self.endpointId = endpointId
    self.isSessionActive = isSessionActive
    self.displayStatus = displayStatus
    self.currentTool = currentTool
    self.showsOrbitStatusIndicator = showsOrbitStatusIndicator
    self.chatViewMode = chatViewMode
    _scrollCommand = scrollCommand
    self.onJumpToLatest = onJumpToLatest
    self.onFollowStateChanged = onFollowStateChanged
    _viewModel = State(
      initialValue: ConversationViewModel(
        sessionId: sessionId,
        session: session,
        viewMode: chatViewMode
      )
    )
  }

  var body: some View {
    ZStack {
      Color.backgroundPrimary
        .ignoresSafeArea()

      content
    }
    .task(id: bindingIdentity) {
      await runLifecycle()
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

  private func runLifecycle() async {
    viewModel.bind(sessionId: sessionId, session: session, viewMode: chatViewMode)

    guard let sessionId, !sessionId.isEmpty else {
      await viewModel.refresh()
      return
    }

    // Keep bind, initial refresh, and event consumption in one ordered lifecycle
    // task so replayed row deltas cannot race a later state reset.
    let (stream, id) = session.transport.events()
    defer {
      session.transport.removeEventListener(id: id)
      session.transport.unsubscribe(surfaces: [.conversation])
    }

    session.transport.subscribe(surfaces: [.conversation])
    await viewModel.refresh()
    await consumeConversationEvents(stream, sessionId: sessionId)
  }

  private func consumeConversationEvents(
    _ stream: AsyncStream<ServerSessionTransport.Event>,
    sessionId: String
  ) async {
    for await event in stream {
      guard !Task.isCancelled else { break }
      guard viewModel.currentSessionId == sessionId else { break }
      switch event {
        case let .conversationRowsChanged(delta):
          viewModel.handleConversationRowDelta(delta)
        case .invalidated where event.invalidates(.conversation):
          viewModel.requestForcedResync(revision: session.transport.latestRevision)
        case .invalidated:
          continue
      }
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
    session: ServerSessionContext.preview(),
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
