import SwiftUI

#if os(macOS)

  struct ConversationMacDetailView: View {
    let session: ScopedSessionID
    let conversationStore: ConversationStore
    let obs: SessionObservable
    let provider: Provider
    let model: String?
    let currentTool: String?
    let pendingToolName: String?
    let pendingPermissionDetail: String?
    let currentPrompt: String?
    let chatViewMode: ChatViewMode
    let loadState: ConversationViewLoadState
    let remainingLoadCount: Int
    let isPinnedToBottom: Bool
    let unreadCount: Int
    let selectedWorkerID: String?
    let focusWorkerInDeck: ((String) -> Void)?
    let onLoadMore: () -> Void

    @State private var runtime: ConversationDetailRuntime
    @State private var expandedToolIDs: Set<String> = []
    @State private var expandedActivityGroupIDs: Set<String> = []

    init(
      session: ScopedSessionID,
      conversationStore: ConversationStore,
      obs: SessionObservable,
      provider: Provider,
      model: String?,
      currentTool: String?,
      pendingToolName: String?,
      pendingPermissionDetail: String?,
      currentPrompt: String?,
      chatViewMode: ChatViewMode,
      loadState: ConversationViewLoadState,
      remainingLoadCount: Int,
      isPinnedToBottom: Bool,
      unreadCount: Int,
      selectedWorkerID: String?,
      focusWorkerInDeck: ((String) -> Void)?,
      onLoadMore: @escaping () -> Void
    ) {
      self.session = session
      self.conversationStore = conversationStore
      self.obs = obs
      self.provider = provider
      self.model = model
      self.currentTool = currentTool
      self.pendingToolName = pendingToolName
      self.pendingPermissionDetail = pendingPermissionDetail
      self.currentPrompt = currentPrompt
      self.chatViewMode = chatViewMode
      self.loadState = loadState
      self.remainingLoadCount = remainingLoadCount
      self.isPinnedToBottom = isPinnedToBottom
      self.unreadCount = unreadCount
      self.selectedWorkerID = selectedWorkerID
      self.focusWorkerInDeck = focusWorkerInDeck
      self.onLoadMore = onLoadMore
      _runtime = State(initialValue: ConversationDetailRuntime(
        session: session,
        clients: conversationStore.serverClients,
        provider: provider,
        model: model
      ))
    }

    var body: some View {
      MacTimelineView(
        viewState: MacTimelineViewStateBuilder.build(
        renderStore: runtime.renderStore,
        messagesByID: Dictionary(uniqueKeysWithValues: conversationStore.messages.map { ($0.id, $0) }),
        chatViewMode: chatViewMode,
        expansionState: .init(expandedActivityGroupIDs: expandedActivityGroupIDs),
        expandedToolIDs: expandedToolIDs,
        loadState: loadState,
        remainingLoadCount: remainingLoadCount,
        isPinnedToBottom: isPinnedToBottom,
        unreadCount: unreadCount
      ),
      onLoadMore: onLoadMore,
      onToggleToolExpansion: toggleToolExpansion(messageID:),
      onToggleActivityExpansion: toggleActivityExpansion(anchorID:),
      onFocusWorker: focusWorkerInDeck
    )
      .task(id: session) {
        runtime = ConversationDetailRuntime(
          session: session,
          clients: conversationStore.serverClients,
          provider: provider,
          model: model
        )
        expandedToolIDs = []
        expandedActivityGroupIDs = []
        syncAll()
      }
      .onAppear {
        syncAll()
      }
      .onChange(of: conversationStore.messagesRevision) { _, _ in
        syncStructure()
      }
      .onChange(of: conversationStore.streamingPatchRevision) { _, _ in
        syncStreamingPatch()
      }
      .onChange(of: metadataRevisionSignature) { _, _ in
        syncMetadata()
      }
    }

    private var metadataRevisionSignature: Int {
      var hasher = Hasher()
      hasher.combine(obs.workStatus)
      hasher.combine(currentTool)
      hasher.combine(obs.pendingApprovalId)
      hasher.combine(obs.pendingQuestion)
      hasher.combine(pendingToolName)
      hasher.combine(pendingPermissionDetail)
      hasher.combine(currentPrompt)
      hasher.combine(obs.approvalVersion)
      hasher.combine(obs.subagents.count)
      for worker in obs.subagents {
        hasher.combine(worker.id)
        hasher.combine(worker.status?.rawValue)
        hasher.combine(worker.label)
        hasher.combine(worker.taskSummary)
        hasher.combine(worker.resultSummary)
        hasher.combine(worker.errorSummary)
        hasher.combine(worker.lastActivityAt)
      }
      for workerID in obs.subagentTools.keys.sorted() {
        hasher.combine(workerID)
        hasher.combine(obs.subagentTools[workerID]?.count ?? 0)
      }
      for workerID in obs.subagentMessages.keys.sorted() {
        hasher.combine(workerID)
        hasher.combine(obs.subagentMessages[workerID]?.count ?? 0)
      }
      hasher.combine(obs.tokenUsage?.inputTokens)
      hasher.combine(obs.tokenUsage?.outputTokens)
      hasher.combine(obs.tokenUsage?.cachedTokens)
      hasher.combine(obs.tokenUsageSnapshotKind)
      hasher.combine(selectedWorkerID)
      return hasher.finalize()
    }

    private func syncAll() {
      syncStructure()
      syncMetadata()
      syncStreamingPatch()
    }

    private func syncStructure() {
      runtime.hydrateStructure(
        messages: conversationStore.messages,
        oldestLoadedSequence: conversationStore.oldestLoadedSequence,
        newestLoadedSequence: conversationStore.newestLoadedSequence,
        hasMoreHistoryBefore: conversationStore.hasMoreHistoryBefore
      )
    }

    private func syncMetadata() {
      runtime.hydrateMetadata(
        ConversationMetadataInput(
          isSessionActive: obs.isActive,
          workStatus: obs.workStatus,
          currentTool: currentTool,
          pendingToolName: pendingToolName,
          pendingPermissionDetail: pendingPermissionDetail,
          currentPrompt: currentPrompt,
          approval: obs.pendingApproval,
          pendingApprovalId: obs.pendingApprovalId,
          approvalVersion: obs.approvalVersion,
          pendingQuestion: obs.pendingQuestion,
          workers: obs.subagents,
          selectedWorkerID: selectedWorkerID,
          toolsByWorker: obs.subagentTools,
          messagesByWorker: obs.subagentMessages,
          tokenUsage: obs.tokenUsage,
          tokenUsageSnapshotKind: obs.tokenUsageSnapshotKind,
          provider: provider,
          model: model
        )
      )
    }

    private func syncStreamingPatch() {
      guard let patch = conversationStore.latestStreamingPatch,
            let message = conversationStore.messages.first(where: { $0.id == patch.messageId })
      else { return }

      if message.isInProgress {
        runtime.applyStreaming(.replace(
          messageID: message.id,
          content: message.content,
          invalidatesHeight: false
        ))
      } else {
        runtime.applyStreaming(.finalize(
          messageID: message.id,
          content: message.content,
          invalidatesHeight: false
        ))
      }
    }

    private func toggleToolExpansion(messageID: String) {
      if expandedToolIDs.contains(messageID) {
        expandedToolIDs.remove(messageID)
      } else {
        expandedToolIDs.insert(messageID)
      }
    }

    private func toggleActivityExpansion(anchorID: String) {
      if expandedActivityGroupIDs.contains(anchorID) {
        expandedActivityGroupIDs.remove(anchorID)
      } else {
        expandedActivityGroupIDs.insert(anchorID)
      }
    }
  }

#endif
