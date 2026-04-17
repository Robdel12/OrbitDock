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
  var state = SessionDetailWorkerState.empty
  var rosterPresentation: SessionWorkerRosterPresentation?
  var detailPresentation: SessionWorkerDetailPresentation?

  @ObservationIgnored private var detailLoadTask: Task<Void, Never>?
  @ObservationIgnored private var detailLoadRequestID = 0

  func reset() {
    cancelDetailLoad()
    selectedWorkerId = nil
    state = .empty
    rosterPresentation = nil
    detailPresentation = nil
  }

  func apply(snapshotState: SessionDetailWorkerState, layoutConfig: LayoutConfiguration) {
    let visibleWorkerIDs = Set(snapshotState.subagents.map(\.id))
    let preservedTools = state.subagentTools.filter { visibleWorkerIDs.contains($0.key) }
    let preservedMessages = state.subagentMessages.filter { visibleWorkerIDs.contains($0.key) }

    state = SessionDetailWorkerState(
      subagents: snapshotState.subagents,
      subagentTools: preservedTools,
      subagentMessages: preservedMessages,
      timelineRevision: snapshotState.timelineRevision
    )

    rosterPresentation = SessionWorkerRosterPlanner.presentation(subagents: state.subagents)
    syncSelectedWorker(layoutConfig: layoutConfig)
  }

  func syncLayout(_ layoutConfig: LayoutConfiguration) {
    syncDetailPresentation(layoutConfig: layoutConfig)
  }

  func loadDetails(
    sessionId: String,
    session: ServerSessionContext,
    layoutConfig: LayoutConfiguration,
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

      async let toolsRequest = try? session.api.fetchSubagentTools(subagentId: workerId)
      async let messagesRequest = try? session.api.fetchSubagentMessages(subagentId: workerId)

      let tools = await toolsRequest
      let messages = await messagesRequest

      guard !Task.isCancelled else { return }
      guard requestID == detailLoadRequestID else { return }
      guard selectedWorkerId == workerId else { return }

      state.subagentTools[workerId] = tools ?? []
      state.subagentMessages[workerId] = messages ?? []
      syncDetailPresentation(layoutConfig: layoutConfig)
    }
  }

  func select(
    workerId: String,
    sessionId: String,
    session: ServerSessionContext,
    layoutConfig: LayoutConfiguration
  ) {
    guard !workerId.isEmpty else { return }
    selectedWorkerId = workerId
    syncDetailPresentation(layoutConfig: layoutConfig)
    loadDetails(
      sessionId: sessionId,
      session: session,
      layoutConfig: layoutConfig,
      for: workerId
    )
  }

  func focus(
    workerId: String,
    sessionId: String,
    session: ServerSessionContext,
    layoutConfig: LayoutConfiguration
  ) {
    select(
      workerId: workerId,
      sessionId: sessionId,
      session: session,
      layoutConfig: layoutConfig
    )
  }

  func cancelDetailLoad() {
    detailLoadTask?.cancel()
    detailLoadTask = nil
    detailLoadRequestID += 1
  }

  private func syncSelectedWorker(layoutConfig: LayoutConfiguration) {
    let nextSelectedWorkerId = SessionWorkerRosterPlanner.preferredSelectedWorkerID(
      currentSelectionID: selectedWorkerId,
      subagents: state.subagents
    )

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
      state.subagentTools[selectedWorkerId] != nil
      || state.subagentMessages[selectedWorkerId] != nil

    guard hasLoadedWorkerPayload else {
      detailPresentation = nil
      return
    }

    detailPresentation = SessionWorkerRosterPlanner.detailPresentation(
      subagents: state.subagents,
      selectedWorkerID: selectedWorkerId,
      toolsByWorker: state.subagentTools,
      messagesByWorker: state.subagentMessages,
      timelineEntries: []
    )
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
