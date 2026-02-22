//
//  ConversationView.swift
//  OrbitDock
//

import OSLog
import SwiftUI

struct ConversationView: View {
  let sessionId: String?
  var isSessionActive: Bool = false
  var workStatus: Session.WorkStatus = .unknown
  var currentTool: String?
  var pendingToolName: String?
  var pendingToolInput: String?
  var provider: Provider = .claude
  var model: String?
  var onNavigateToReviewFile: ((String, Int) -> Void)? // (filePath, lineNumber) deep link from review card

  @Environment(ServerAppState.self) private var serverState

  @AppStorage("chatViewMode") private var chatViewMode: ChatViewMode = .focused

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

  /// Pre-computed per-message metadata to avoid O(n²) in ForEach
  struct MessageMeta {
    let turnsAfter: Int?
    let nthUserMessage: Int?
  }

  private var effectiveDisplayedCount: Int {
    guard !messages.isEmpty else { return 0 }
    if displayedCount <= 0 { return messages.count }
    return min(displayedCount, messages.count)
  }

  var displayedMessages: [TranscriptMessage] {
    guard !messages.isEmpty else { return [] }
    let startIndex = max(0, messages.count - effectiveDisplayedCount)
    return Array(messages[startIndex...])
  }

  var hasMoreMessages: Bool {
    effectiveDisplayedCount < messages.count
  }

  var body: some View {
    ZStack {
      // Background
      Color.backgroundPrimary
        .ignoresSafeArea()

      if isLoading {
        ConversationLoadingView()
      } else if messages.isEmpty {
        ConversationEmptyStateView()
      } else {
        VStack(spacing: 0) {
          // Fork origin banner (persistent, above scroll)
          if let sid = sessionId, let sourceId = serverState.session(sid).forkedFrom {
            ConversationForkOriginBanner(
              sourceSessionId: sourceId,
              sourceName: serverState.sessions.first(where: { $0.id == sourceId })?.displayName
            )
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)
          }

          conversationThread
        }
      }
    }
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
    ZStack(alignment: .topTrailing) {
      ConversationCollectionView(
        messages: displayedMessages,
        chatViewMode: chatViewMode,
        isSessionActive: isSessionActive,
        workStatus: workStatus,
        currentTool: currentTool,
        pendingToolName: pendingToolName,
        pendingToolInput: pendingToolInput,
        provider: provider,
        model: model,
        sessionId: sessionId,
        serverState: serverState,
        hasMoreMessages: hasMoreMessages,
        currentPrompt: currentPrompt,
        messageCount: messages.count,
        remainingLoadCount: min(pageSize, messages.count - effectiveDisplayedCount),
        openFileInReview: openFileInReview,
        onLoadMore: { displayedCount = min(displayedCount + pageSize, messages.count) },
        onNavigateToReviewFile: onNavigateToReviewFile,
        isPinned: $isPinned,
        unreadCount: $unreadCount,
        scrollToBottomTrigger: $scrollToBottomTrigger
      )

      ConversationViewModeToggle(chatViewMode: $chatViewMode)
        .padding(.top, 8)
        .padding(.trailing, 12)
    }
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

    let serverMessages = serverState.session(sid).messages
    messages = serverMessages
    displayedCount = min(pageSize, serverMessages.count)

    isLoading = false
    logDebugState("load_messages")
  }

  private func refreshFromServerStateIfNeeded() {
    guard let sid = sessionId else { return }
    let serverMessages = serverState.session(sid).messages
    let previousRefreshCount = messages.count

    // Fast path: nothing changed at a render-relevant level.
    if messages.count == serverMessages.count,
       messages.indices.allSatisfy({ i in
         messages[i].id == serverMessages[i].id &&
           Self.messageRenderEquivalent(messages[i], serverMessages[i])
       })
    {
      if displayedCount <= 0, !messages.isEmpty {
        displayedCount = min(pageSize, messages.count)
        logDebugState("fast_path_repair_displayed_count")
      }
      isLoading = false
      return
    }

    // Append path: server has more messages and preserves ID ordering.
    let sharesPrefixIds = !messages.isEmpty &&
      serverMessages.count >= messages.count &&
      messages.indices.allSatisfy { messages[$0].id == serverMessages[$0].id }

    if serverMessages.count >= messages.count,
       sharesPrefixIds
    {
      // Update changed existing messages (e.g., streaming content/tool output).
      for i in messages.indices {
        if i < serverMessages.count, !Self.messageRenderEquivalent(messages[i], serverMessages[i]) {
          messages[i] = serverMessages[i]
        }
      }

      // Append genuinely new messages
      if serverMessages.count > messages.count {
        messages.append(contentsOf: serverMessages[messages.count...])
      }
    } else {
      // Structural change (undo/rollback/initial load) — full replace
      messages = serverMessages
    }

    if !messages.isEmpty {
      // Grow displayedCount by new message delta — don't jump to full count.
      // This keeps the native table/collection view manageable while ensuring
      // new streaming content is always visible.
      let delta = max(0, messages.count - previousRefreshCount)
      displayedCount = max(displayedCount + delta, effectiveDisplayedCount)
      if displayedCount <= 0 {
        displayedCount = min(pageSize, messages.count)
      }
    } else {
      displayedCount = 0
    }

    isLoading = false
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

  static func messageRenderEquivalent(_ lhs: TranscriptMessage, _ rhs: TranscriptMessage) -> Bool {
    lhs.id == rhs.id &&
      lhs.type == rhs.type &&
      lhs.content == rhs.content &&
      lhs.toolName == rhs.toolName &&
      lhs.toolOutput == rhs.toolOutput &&
      lhs.toolDuration == rhs.toolDuration &&
      lhs.inputTokens == rhs.inputTokens &&
      lhs.outputTokens == rhs.outputTokens &&
      lhs.isInProgress == rhs.isInProgress &&
      lhs.thinking == rhs.thinking &&
      lhs.images == rhs.images
  }

  /// Single-pass computation of per-message metadata (turnsAfter, nthUserMessage).
  /// Replaces O(n²) inline closures that scanned the array per message in ForEach.
  static func computeMessageMetadata(_ msgs: [TranscriptMessage]) -> [String: MessageMeta] {
    var result: [String: MessageMeta] = [:]
    result.reserveCapacity(msgs.count)

    // First pass: assign nthUserMessage indices
    var userCount = 0
    var userIndices: [Int] = [] // indices of user messages in msgs
    for (i, msg) in msgs.enumerated() {
      if msg.isUser {
        result[msg.id] = MessageMeta(turnsAfter: 0, nthUserMessage: userCount)
        userCount += 1
        userIndices.append(i)
      } else {
        result[msg.id] = MessageMeta(turnsAfter: nil, nthUserMessage: nil)
      }
    }

    // Second pass: compute turnsAfter for each user message
    // turnsAfter = number of user messages after this one, or 1 if there's at least a response
    for (rank, msgIndex) in userIndices.enumerated() {
      let userMsgsAfter = userIndices.count - rank - 1
      let turnsAfter: Int
      if userMsgsAfter > 0 {
        turnsAfter = userMsgsAfter
      } else {
        // Last user message — check if there's any response after it
        let hasResponseAfter = msgs[(msgIndex + 1)...].contains { !$0.isUser }
        turnsAfter = hasResponseAfter ? 1 : 0
      }

      let existing = result[msgs[msgIndex].id]
      result[msgs[msgIndex].id] = MessageMeta(
        turnsAfter: turnsAfter > 0 ? turnsAfter : nil,
        nthUserMessage: existing?.nthUserMessage
      )
    }

    return result
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
