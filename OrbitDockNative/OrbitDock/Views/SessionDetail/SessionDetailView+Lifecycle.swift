import SwiftUI

extension SessionDetailView {
  func handleOnAppear() {
    let plan = SessionDetailLifecyclePlanner.onAppearPlan(
      shouldSubscribeToServerSession: shouldSubscribeToServerSession,
      isDirect: obs.isDirect,
      isPinned: isPinned
    )

    guard plan.shouldSubscribe else { return }

    scopedServerState.subscribeToSession(sessionId, recoveryGoal: .coherentRecent)
    scopedServerState.setSessionAutoMarkRead(sessionId, enabled: plan.autoMarkReadEnabled)
    syncSelectedWorker()

    guard plan.shouldLoadApprovalHistory else { return }
    loadApprovalHistory()
  }

  func handleOnDisappear() {
    let plan = SessionDetailLifecyclePlanner.onDisappearPlan(
      shouldSubscribeToServerSession: shouldSubscribeToServerSession
    )

    if plan.shouldSetAutoMarkRead {
      scopedServerState.setSessionAutoMarkRead(sessionId, enabled: plan.autoMarkReadEnabled)
    }
    if plan.shouldUnsubscribe {
      scopedServerState.unsubscribeFromSession(sessionId)
    }
  }

  func handlePinnedChange(_ pinned: Bool) {
    guard let enabled = SessionDetailLifecyclePlanner.autoMarkReadEnabled(
      shouldSubscribeToServerSession: shouldSubscribeToServerSession,
      isPinned: pinned
    ) else {
      return
    }
    scopedServerState.setSessionAutoMarkRead(sessionId, enabled: enabled)
  }

  func handleDiffChange(oldDiff: String?, newDiff: String?) {
    guard SessionDetailLifecyclePlanner.shouldRevealDiffBanner(
      isDirect: obs.isDirect,
      oldDiff: oldDiff,
      newDiff: newDiff,
      layoutConfig: layoutConfig
    ) else {
      return
    }
    withAnimation(Motion.standard) {
      showDiffBanner = true
    }
    Task {
      try? await Task.sleep(for: .seconds(8))
      await MainActor.run {
        withAnimation(Motion.standard) {
          showDiffBanner = false
        }
      }
    }
  }

  private func loadApprovalHistory() {
    Task {
      if let response = try? await scopedServerState.clients.approvals.listApprovals(sessionId: sessionId) {
        scopedServerState.session(sessionId).approvalHistory = response.approvals
      }
    }
  }

  func syncSelectedWorker() {
    selectedWorkerId = SessionWorkerRosterPlanner.preferredSelectedWorkerID(
      currentSelectionID: selectedWorkerId,
      subagents: obs.subagents
    )
  }

  func loadSelectedWorkerTools(for workerId: String? = nil) {
    guard showWorkerPanel else { return }
    guard let workerId = workerId ?? selectedWorkerId else { return }
    scopedServerState.getSubagentTools(sessionId: sessionId, subagentId: workerId)
    scopedServerState.getSubagentMessages(sessionId: sessionId, subagentId: workerId)
  }

  func selectWorkerInPanel(_ workerId: String) {
    guard !workerId.isEmpty else { return }
    selectedWorkerId = workerId
    loadSelectedWorkerTools(for: workerId)
  }

  func focusWorkerInDeck(_ workerId: String) {
    guard !workerId.isEmpty else { return }
    showWorkerPanel = true
    selectWorkerInPanel(workerId)
  }
}
