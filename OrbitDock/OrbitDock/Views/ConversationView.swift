//
//  ConversationView.swift
//  OrbitDock
//

import OSLog
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
  var chatViewMode: ChatViewMode = .focused
  var onNavigateToReviewFile: ((String, Int) -> Void)? // (filePath, lineNumber) deep link from review card

  @Environment(ServerAppState.self) private var serverState

  @State private var messages: [TranscriptMessage] = []
  @State private var currentPrompt: String?
  @State private var isLoading = true
  @State private var loadedSessionId: String?
  @State private var displayedCount: Int = 50
  @State private var refreshTask: Task<Void, Never>?
  @State private var hasPendingRefresh = false

  // Auto-follow state - controlled by parent
  @Binding var isPinned: Bool
  @Binding var unreadCount: Int
  @Binding var scrollToBottomTrigger: Int

  private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OrbitDock", category: "conversation-view")
  private let pageSize = 50
  private let refreshCadence: Duration = {
    #if os(macOS)
      .milliseconds(75)
    #else
      .milliseconds(33)
    #endif
  }()

  private var effectiveDisplayedCount: Int {
    messages.count
  }

  var displayedMessages: [TranscriptMessage] {
    messages
  }

  var hasMoreMessages: Bool {
    guard let sid = sessionId else { return false }
    return serverState.session(sid).hasMoreHistoryBefore
  }

  var remainingLoadCount: Int {
    guard let sid = sessionId else { return 0 }
    let totalCount = serverState.session(sid).totalMessageCount
    return min(pageSize, max(0, totalCount - messages.count))
  }

  var body: some View {
    ZStack {
      // Background
      Color.backgroundPrimary
        .ignoresSafeArea()

      if isLoading {
        ConversationLoadingView()
          .transition(.opacity)
      } else if messages.isEmpty {
        ConversationEmptyStateView()
          .transition(.opacity)
      } else {
        VStack(spacing: 0) {
          // Fork origin banner (persistent, above scroll)
          if let sid = sessionId, let sourceId = serverState.session(sid).forkedFrom {
            ConversationForkOriginBanner(
              sourceSessionId: sourceId,
              sourceEndpointId: endpointId,
              sourceName: serverState.sessions.first(where: { $0.id == sourceId })?.displayName
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
    .animation(Motion.fade, value: isLoading)
    .animation(Motion.fade, value: messages.isEmpty)
    .onAppear {
      loadMessagesIfNeeded()
      queueRefreshFromServerState()
    }
    .onDisappear {
      refreshTask?.cancel()
      refreshTask = nil
      hasPendingRefresh = false
    }
    .onChange(of: sessionId) { _, _ in
      loadMessagesIfNeeded()
      queueRefreshFromServerState()
    }
    // React to server message changes (appends, updates, undo, rollback) — only THIS session.
    // Coalesce rapid revision bumps into a throttled refresh loop so streaming never starves.
    .onChange(of: serverState.session(sessionId ?? "").messagesRevision) { _, _ in
      queueRefreshFromServerState()
    }
  }

  // MARK: - Main Thread View

  @Environment(\.openFileInReview) private var openFileInReview

  private var conversationThread: some View {
    ConversationCollectionView(
      messages: displayedMessages,
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
      messageCount: sessionId.map { max(messages.count, serverState.session($0).totalMessageCount) } ?? messages.count,
      remainingLoadCount: remainingLoadCount,
      openFileInReview: openFileInReview,
      onLoadMore: {
        guard let sid = sessionId else { return }
        serverState.loadOlderMessages(sessionId: sid, limit: pageSize)
      },
      onNavigateToReviewFile: onNavigateToReviewFile,
      isPinned: $isPinned,
      unreadCount: $unreadCount,
      scrollToBottomTrigger: $scrollToBottomTrigger
    )
  }

  // MARK: - Subscriptions & Data Loading

  private func loadMessagesIfNeeded() {
    guard sessionId != loadedSessionId else { return }
    refreshTask?.cancel()
    refreshTask = nil
    hasPendingRefresh = false
    loadedSessionId = sessionId
    messages = []
    currentPrompt = nil
    isLoading = true
    // Note: isPinned and unreadCount are now managed by parent

    guard let sid = sessionId else {
      isLoading = false
      return
    }

    let obs = serverState.session(sid)
    let serverMessages = ConversationRenderMessageNormalizer.normalize(
      obs.messages,
      sessionId: sid,
      source: "load"
    )
    messages = serverMessages
    displayedCount = serverMessages.count

    // Only clear loading if we already have messages or the snapshot confirmed empty.
    // Otherwise keep loading visible until the refresh loop copies snapshot data.
    if !serverMessages.isEmpty || obs.hasConversationSeed {
      isLoading = false
    }
    logDebugState("load_messages")
  }

  private func refreshFromServerStateIfNeeded() {
    guard let sid = sessionId else { return }
    let obs = serverState.session(sid)
    let snapshotReceived = obs.hasConversationSeed
    let serverMessages = ConversationRenderMessageNormalizer.normalize(
      obs.messages,
      sessionId: sid,
      source: "refresh"
    )
    let syncResult = ConversationMessageSync.reconcile(
      localMessages: messages,
      serverMessages: serverMessages,
      displayedCount: messages.count,
      pageSize: pageSize,
      mutation: obs.lastMessageMutation
    )

    if displayedCount != syncResult.displayedCount {
      displayedCount = syncResult.displayedCount
      if !syncResult.didChange, !messages.isEmpty {
        logDebugState("fast_path_repair_displayed_count")
      }
    }

    guard syncResult.didChange else {
      if snapshotReceived { isLoading = false }
      return
    }

    let normalizedMessages = ConversationRenderMessageNormalizer.normalize(
      syncResult.messages,
      sessionId: sid,
      source: "sync-result"
    )
    messages = normalizedMessages
    let normalizedDisplayedCount = min(syncResult.displayedCount, normalizedMessages.count)
    if displayedCount != normalizedDisplayedCount {
      displayedCount = normalizedDisplayedCount
    }

    if snapshotReceived { isLoading = false }
    logDebugState("refresh_messages")
  }

  private func queueRefreshFromServerState() {
    hasPendingRefresh = true
    guard refreshTask == nil else { return }

    refreshTask = Task { @MainActor in
      while hasPendingRefresh, !Task.isCancelled {
        hasPendingRefresh = false
        refreshFromServerStateIfNeeded()
        try? await Task.sleep(for: refreshCadence)
      }
      refreshTask = nil
    }
  }

  private func logDebugState(_ reason: String) {
    #if DEBUG
      let sid = sessionId ?? "nil"
      let distinctIDs = Set(self.messages.map(\.id)).count
      let duplicateIDs = max(0, self.messages.count - distinctIDs)
      let emptyIDs = self.messages.reduce(0) { partial, message in
        partial + (message.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 1 : 0)
      }
      let nonEmptyContent = self.messages.reduce(0) { partial, message in
        partial + (message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1)
      }
      let toolMessages = self.messages.reduce(0) { partial, message in
        partial + (message.type == .tool ? 1 : 0)
      }
      let userMessages = self.messages.reduce(0) { partial, message in
        partial + (message.type == .user ? 1 : 0)
      }
      let assistantMessages = self.messages.reduce(0) { partial, message in
        partial + (message.type == .assistant ? 1 : 0)
      }
      let thinkingMessages = self.messages.reduce(0) { partial, message in
        partial + (message.type == .thinking ? 1 : 0)
      }
      let toolOutputs = self.messages.reduce(0) { partial, message in
        let hasOutput = !(message.toolOutput?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return partial + (hasOutput ? 1 : 0)
      }
      logger.debug(
        "conversation state reason=\(reason, privacy: .public) sid=\(sid, privacy: .public) messages=\(self.messages.count, privacy: .public) displayed=\(self.displayedCount, privacy: .public) effective=\(self.effectiveDisplayedCount, privacy: .public) rendered=\(self.displayedMessages.count, privacy: .public) duplicate_ids=\(duplicateIDs, privacy: .public) empty_ids=\(emptyIDs, privacy: .public) non_empty_content=\(nonEmptyContent, privacy: .public) users=\(userMessages, privacy: .public) assistants=\(assistantMessages, privacy: .public) thinking=\(thinkingMessages, privacy: .public) tools=\(toolMessages, privacy: .public) tool_outputs=\(toolOutputs, privacy: .public) pinned=\(self.isPinned, privacy: .public) unread=\(self.unreadCount, privacy: .public) mode=\(self.chatViewMode.rawValue, privacy: .public)"
      )
    #endif
  }

}

struct ConversationMessageSyncResult {
  let messages: [TranscriptMessage]
  let displayedCount: Int
  let didChange: Bool
}

enum ConversationMessageSync {
  static func reconcile(
    localMessages: [TranscriptMessage],
    serverMessages: [TranscriptMessage],
    displayedCount: Int,
    pageSize: Int,
    mutation: ConversationMessageMutation?
  ) -> ConversationMessageSyncResult {
    if let mutation {
      switch mutation.kind {
        case .replaceAll:
          return fullReplace(
            localMessages: localMessages,
            serverMessages: serverMessages,
            displayedCount: displayedCount,
            pageSize: pageSize
          )
        case let .upsert(message):
          if let incremental = applyIncremental(
            localMessages: localMessages,
            serverMessages: serverMessages,
            displayedCount: displayedCount,
            pageSize: pageSize,
            message: message
          ) {
            return incremental
          }
          return fullReplace(
            localMessages: localMessages,
            serverMessages: serverMessages,
            displayedCount: displayedCount,
            pageSize: pageSize
          )
      }
    }

    return fullReplace(
      localMessages: localMessages,
      serverMessages: serverMessages,
      displayedCount: displayedCount,
      pageSize: pageSize
    )
  }

  static func messageRenderEquivalent(_ lhs: TranscriptMessage, _ rhs: TranscriptMessage) -> Bool {
    lhs.id == rhs.id &&
      lhs.type == rhs.type &&
      lhs.content == rhs.content &&
      lhs.toolName == rhs.toolName &&
      lhs.toolInputRenderSignature == rhs.toolInputRenderSignature &&
      lhs.toolOutput == rhs.toolOutput &&
      lhs.toolDuration == rhs.toolDuration &&
      lhs.inputTokens == rhs.inputTokens &&
      lhs.outputTokens == rhs.outputTokens &&
      lhs.isInProgress == rhs.isInProgress &&
      lhs.thinking == rhs.thinking &&
      lhs.images == rhs.images
  }

  private static func applyIncremental(
    localMessages: [TranscriptMessage],
    serverMessages: [TranscriptMessage],
    displayedCount: Int,
    pageSize: Int,
    message: TranscriptMessage
  ) -> ConversationMessageSyncResult? {
    guard localMessages.count <= serverMessages.count else { return nil }

    var nextMessages = localMessages
    var didChange = false

    if nextMessages.count < serverMessages.count {
      nextMessages.append(contentsOf: serverMessages[nextMessages.count...])
      didChange = true
    }

    guard let index = nextMessages.firstIndex(where: { $0.id == message.id }) else { return nil }

    if !messageRenderEquivalent(nextMessages[index], message) {
      nextMessages[index] = message
      didChange = true
    }

    let resultMessages = didChange ? nextMessages : localMessages
    return ConversationMessageSyncResult(
      messages: resultMessages,
      displayedCount: adjustedDisplayedCount(
        currentDisplayedCount: displayedCount,
        previousMessages: localMessages,
        nextMessages: resultMessages,
        pageSize: pageSize
      ),
      didChange: didChange
    )
  }

  private static func fullReplace(
    localMessages: [TranscriptMessage],
    serverMessages: [TranscriptMessage],
    displayedCount: Int,
    pageSize: Int
  ) -> ConversationMessageSyncResult {
    let didChange = !messagesRenderEquivalent(localMessages, serverMessages)
    let resultMessages = didChange ? serverMessages : localMessages
    return ConversationMessageSyncResult(
      messages: resultMessages,
      displayedCount: adjustedDisplayedCount(
        currentDisplayedCount: displayedCount,
        previousMessages: localMessages,
        nextMessages: resultMessages,
        pageSize: pageSize
      ),
      didChange: didChange
    )
  }

  private static func messagesRenderEquivalent(_ lhs: [TranscriptMessage], _ rhs: [TranscriptMessage]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    return lhs.indices.allSatisfy { index in
      lhs[index].id == rhs[index].id && messageRenderEquivalent(lhs[index], rhs[index])
    }
  }

  private static func adjustedDisplayedCount(
    currentDisplayedCount: Int,
    previousMessages: [TranscriptMessage],
    nextMessages: [TranscriptMessage],
    pageSize: Int
  ) -> Int {
    guard !nextMessages.isEmpty else { return 0 }

    let previousEffectiveDisplayedCount: Int = {
      guard !previousMessages.isEmpty else { return 0 }
      if currentDisplayedCount <= 0 { return previousMessages.count }
      return min(currentDisplayedCount, previousMessages.count)
    }()

    let delta = max(0, nextMessages.count - previousMessages.count)
    var nextDisplayedCount = max(currentDisplayedCount + delta, previousEffectiveDisplayedCount)
    if nextDisplayedCount <= 0 {
      nextDisplayedCount = min(pageSize, nextMessages.count)
    }
    return min(nextDisplayedCount, nextMessages.count)
  }
}

// MARK: - Preview

#Preview {
  @Previewable @State var isPinned = true
  @Previewable @State var unreadCount = 0
  @Previewable @State var scrollTrigger = 0

  ConversationView(
    sessionId: nil,
    isSessionActive: true,
    workStatus: .working,
    currentTool: "Edit",
    provider: .claude,
    model: "claude-opus-4-6",
    isPinned: $isPinned,
    unreadCount: $unreadCount,
    scrollToBottomTrigger: $scrollTrigger
  )
  .environment(ServerAppState())
  .frame(width: 700, height: 600)
  .background(Color.backgroundPrimary)
}
