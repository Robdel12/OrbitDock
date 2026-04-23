import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class SessionDetailConversationModel {
  var scrollCommand: ConversationScrollCommand?
  var followState = ConversationFollowState.initial

  @ObservationIgnored private var scrollCommandNonce = 0

  func reset() {
    followState = .initial
    scrollCommand = nil
    scrollCommandNonce = 0
  }

  func handleFollowStateChanged(_ state: ConversationFollowState) {
    followState = state
  }

  func jumpToLatest() {
    scrollCommandNonce += 1
    scrollCommand = .jumpToLatest(nonce: scrollCommandNonce)
  }

  func toggleFollowMode() {
    scrollCommandNonce += 1
    scrollCommand = .toggleFollow(nonce: scrollCommandNonce)
  }

  func openPendingApproval() {
    scrollCommandNonce += 1
    scrollCommand = .openPendingApproval(nonce: scrollCommandNonce)
  }

  func revealMessage(id: String) {
    scrollCommandNonce += 1
    scrollCommand = .revealMessage(id: id, nonce: scrollCommandNonce)
  }
}

@MainActor
@Observable
final class SessionDetailReviewModel {
  var showDiffBanner = false
  var reviewFileId: String?
  var navigateToComment: ServerReviewComment?
  var selectedCommentIds: Set<String> = []

  func reset() {
    showDiffBanner = false
    reviewFileId = nil
    navigateToComment = nil
    selectedCommentIds.removeAll()
  }
}

@MainActor
@Observable
final class SessionDetailTerminalModel {
  var showPanel = false
  var activeTerminalId: String?
  var showInteractiveSheet = false
  var showInlineTerminal = false

  func reset() {
    showPanel = false
    activeTerminalId = nil
    showInteractiveSheet = false
    showInlineTerminal = false
  }
}

@MainActor
@Observable
final class SessionDetailWorkerModel {
  var selectedWorkerId: String?
  var messageDraft = ""
  var isSendingMessage = false
  var state = SessionDetailWorkerState.empty
  var rosterPresentation: SessionWorkerRosterPresentation?
  var detailPresentation: SessionWorkerDetailPresentation?
  var threadConversationViewModel = ConversationViewModel()
  var threadScrollCommand: ConversationScrollCommand?

  @ObservationIgnored private var detailLoadTask: Task<Void, Never>?
  @ObservationIgnored private var detailLoadRequestID = 0
  @ObservationIgnored private var threadScrollCommandNonce = 0

  var hasAgentThreadRoster: Bool {
    !state.agentThreads.isEmpty
  }

  var openedAgentThreadID: String? {
    guard
      let selectedWorkerId,
      state.agentThreads.contains(where: { $0.id == selectedWorkerId })
    else { return nil }
    return selectedWorkerId
  }

  func reset() {
    cancelDetailLoad()
    selectedWorkerId = nil
    messageDraft = ""
    isSendingMessage = false
    state = .empty
    rosterPresentation = nil
    detailPresentation = nil
    threadConversationViewModel = ConversationViewModel()
    threadScrollCommand = nil
    threadScrollCommandNonce = 0
  }

  func apply(snapshotState: SessionDetailWorkerState, layoutConfig: LayoutConfiguration) {
    let visibleWorkerIDs = Set(snapshotState.subagents.map(\.id)).union(state.agentThreads.map(\.id))
    let preservedTools = state.subagentTools.filter { visibleWorkerIDs.contains($0.key) }
    let preservedMessages = state.subagentMessages.filter { visibleWorkerIDs.contains($0.key) }
    let preservedThreads = state.agentThreads.filter { visibleWorkerIDs.contains($0.id) }
    let preservedPages = state.agentThreadPages.filter { visibleWorkerIDs.contains($0.key) }

    state = SessionDetailWorkerState(
      subagents: snapshotState.subagents,
      subagentTools: preservedTools,
      subagentMessages: preservedMessages,
      agentThreads: preservedThreads,
      agentThreadPages: preservedPages,
      timelineRevision: snapshotState.timelineRevision
    )

    rosterPresentation = rosterPresentation(for: state)
    syncSelectedWorker(layoutConfig: layoutConfig)
  }

  func syncLayout(_ layoutConfig: LayoutConfiguration) {
    syncDetailPresentation(layoutConfig: layoutConfig)
  }

  func loadDetails(
    sessionId: String,
    session: ServerSessionContext,
    layoutConfig: LayoutConfiguration,
    chatViewMode: ChatViewMode = .focused,
    for workerId: String? = nil
  ) {
    guard let workerId = workerId ?? selectedWorkerId else { return }

    cancelDetailLoad()
    detailLoadRequestID += 1
    let requestID = detailLoadRequestID

    detailLoadTask = Task {
      defer {
        if requestID == detailLoadRequestID {
          detailLoadTask = nil
        }
      }

      async let threadsRequest = try? session.api.listAgentThreads()
      async let conversationRequest = try? session.api.fetchAgentThreadConversation(threadId: workerId)

      let threads = await threadsRequest
      let conversation = await conversationRequest

      guard !Task.isCancelled else { return }
      guard requestID == detailLoadRequestID else { return }
      guard selectedWorkerId == workerId else { return }

      if let threads {
        state.agentThreads = threads.threads
        rosterPresentation = SessionWorkerRosterPlanner.presentation(agentThreads: threads.threads)
      }
      if let conversation {
        state.agentThreadPages[workerId] = conversation
      }
      if !state.agentThreads.isEmpty {
        bindAgentThreadConversation(
          sessionId: sessionId,
          session: session,
          chatViewMode: chatViewMode,
          threadId: workerId
        )
        if let conversation {
          threadConversationViewModel.applyAgentThreadPage(conversation)
        }
      }
      syncDetailPresentation(layoutConfig: layoutConfig)
    }
  }

  func select(
    workerId: String,
    sessionId: String,
    session: ServerSessionContext,
    layoutConfig: LayoutConfiguration,
    chatViewMode: ChatViewMode = .focused
  ) {
    guard !workerId.isEmpty else { return }
    selectedWorkerId = workerId
    if state.agentThreads.contains(where: { $0.id == workerId }) {
      bindAgentThreadConversation(
        sessionId: sessionId,
        session: session,
        chatViewMode: chatViewMode,
        threadId: workerId
      )
      if let page = state.agentThreadPages[workerId] {
        threadConversationViewModel.applyAgentThreadPage(page)
      }
    }
    syncDetailPresentation(layoutConfig: layoutConfig)
    loadDetails(
      sessionId: sessionId,
      session: session,
      layoutConfig: layoutConfig,
      chatViewMode: chatViewMode,
      for: workerId
    )
  }

  func focus(
    workerId: String,
    sessionId: String,
    session: ServerSessionContext,
    layoutConfig: LayoutConfiguration,
    chatViewMode: ChatViewMode = .focused
  ) {
    select(
      workerId: workerId,
      sessionId: sessionId,
      session: session,
      layoutConfig: layoutConfig,
      chatViewMode: chatViewMode
    )
  }

  func bindAgentThreadConversation(
    sessionId: String,
    session: ServerSessionContext,
    chatViewMode: ChatViewMode,
    threadId: String
  ) {
    threadConversationViewModel.bind(
      sessionId: sessionId,
      session: session,
      viewMode: chatViewMode,
      routeKey: agentThreadConversationRouteKey(sessionId: sessionId, threadId: threadId),
      agentThreadId: threadId
    )
  }

  func jumpThreadConversationToLatest() {
    threadScrollCommandNonce += 1
    threadScrollCommand = .jumpToLatest(nonce: threadScrollCommandNonce)
  }

  func handleThreadConversationFollowStateChanged(_ state: ConversationFollowState) {
    threadConversationViewModel.applyFollowState(state)
  }

  func cancelDetailLoad() {
    detailLoadTask?.cancel()
    detailLoadTask = nil
    detailLoadRequestID += 1
  }

  private func syncSelectedWorker(layoutConfig: LayoutConfiguration) {
    let nextSelectedWorkerId: String? = if !state.agentThreads.isEmpty {
      SessionWorkerRosterPlanner.preferredSelectedWorkerID(
        currentSelectionID: selectedWorkerId,
        agentThreads: state.agentThreads
      )
    } else {
      SessionWorkerRosterPlanner.preferredSelectedWorkerID(
        currentSelectionID: selectedWorkerId,
        subagents: state.subagents
      )
    }

    if selectedWorkerId != nextSelectedWorkerId {
      selectedWorkerId = nextSelectedWorkerId
    }

    syncDetailPresentation(layoutConfig: layoutConfig)
  }

  private func syncDetailPresentation(layoutConfig: LayoutConfiguration) {
    guard layoutConfig != .reviewOnly, let selectedWorkerId else {
      detailPresentation = nil
      return
    }

    let hasLoadedWorkerPayload =
      state.agentThreadPages[selectedWorkerId] != nil
        || state.subagentTools[selectedWorkerId] != nil
        || state.subagentMessages[selectedWorkerId] != nil

    guard hasLoadedWorkerPayload else {
      detailPresentation = nil
      return
    }

    if !state.agentThreads.isEmpty {
      detailPresentation = SessionWorkerRosterPlanner.detailPresentation(
        agentThreads: state.agentThreads,
        selectedWorkerID: selectedWorkerId,
        pageByThread: state.agentThreadPages,
        subagents: state.subagents
      )
    } else {
      detailPresentation = SessionWorkerRosterPlanner.detailPresentation(
        subagents: state.subagents,
        selectedWorkerID: selectedWorkerId,
        toolsByWorker: state.subagentTools,
        messagesByWorker: state.subagentMessages,
        timelineEntries: []
      )
    }
  }

  private func rosterPresentation(for state: SessionDetailWorkerState) -> SessionWorkerRosterPresentation? {
    if !state.agentThreads.isEmpty {
      return SessionWorkerRosterPlanner.presentation(agentThreads: state.agentThreads)
    }
    return SessionWorkerRosterPlanner.presentation(subagents: state.subagents)
  }

  private func agentThreadConversationRouteKey(sessionId: String, threadId: String) -> String {
    "\(sessionId):agent-thread:\(threadId)"
  }
}

@MainActor
@Observable
final class SessionDetailWorktreeCleanupModel {
  var dismissed = false
  var deleteBranchOnCleanup = true
  var isCleaningUp = false
  var errorMessage: String?

  func reset() {
    dismissed = false
    deleteBranchOnCleanup = true
    isCleaningUp = false
    errorMessage = nil
  }

  func bannerState(
    worktreeState: SessionDetailWorktreeState,
    worktreesByRepo: [String: [ServerWorktreeSummary]]
  ) -> SessionDetailWorktreeCleanupBannerState? {
    SessionDetailWorktreeCleanupPlanner.bannerState(
      status: worktreeState.status,
      isWorktree: worktreeState.isWorktree,
      dismissed: dismissed,
      worktree: worktree(
        worktreeState: worktreeState,
        worktreesByRepo: worktreesByRepo
      ),
      branch: worktreeState.branch,
      isCleaningUp: isCleaningUp
    )
  }

  func worktree(
    worktreeState: SessionDetailWorktreeState,
    worktreesByRepo: [String: [ServerWorktreeSummary]]
  ) -> ServerWorktreeSummary? {
    SessionDetailWorktreeCleanupPlanner.resolveWorktree(
      worktreesByRepo: worktreesByRepo,
      worktreeId: worktreeState.worktreeId,
      projectPath: worktreeState.projectPath
    )
  }

  func dismiss() {
    dismissed = true
  }

  func cleanUp(
    worktreeState: SessionDetailWorktreeState,
    worktreesByRepo: [String: [ServerWorktreeSummary]],
    session: ServerSessionContext
  ) {
    guard let request = SessionDetailWorktreeCleanupPlanner.cleanupRequest(
      worktree: worktree(worktreeState: worktreeState, worktreesByRepo: worktreesByRepo),
      deleteBranch: deleteBranchOnCleanup
    ) else {
      return
    }

    isCleaningUp = true
    errorMessage = nil

    Task {
      do {
        try await session.api.removeWorktree(
          worktreeId: request.worktreeId,
          force: request.force,
          deleteBranch: request.deleteBranch
        )
        withAnimation(Motion.gentle) {
          dismissed = true
        }
      } catch {
        errorMessage = error.localizedDescription
      }
      isCleaningUp = false
    }
  }
}
