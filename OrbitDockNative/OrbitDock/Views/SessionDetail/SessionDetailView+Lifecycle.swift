import SwiftUI

extension SessionDetailView {
  func handleOnAppear() {
    let sessionId = self.sessionId
    let endpointId = self.endpointId
    print("[OrbitDock][SessionDetail] onAppear session=\(sessionId) endpoint=\(endpointId)")
    NSLog("[OrbitDock][SessionDetail] onAppear session=%@ endpoint=%@", sessionId, endpointId.uuidString)

    guard !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      print("[OrbitDock][SessionDetail] skipping subscribe — empty sessionId")
      return
    }

    scopedServerState.subscribeToSession(sessionId)
    scopedServerState.setSessionAutoMarkRead(sessionId, enabled: isPinned)
    syncSelectedWorker()

    if obs.isDirect {
      loadApprovalHistory()
    }
  }

  func handleOnDisappear() {
    let sessionId = self.sessionId
    print("[OrbitDock][SessionDetail] onDisappear session=\(sessionId)")

    guard !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

    scopedServerState.setSessionAutoMarkRead(sessionId, enabled: false)
    scopedServerState.unsubscribeFromSession(sessionId)
  }

  func handlePinnedChange(_ pinned: Bool) {
    guard !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    scopedServerState.setSessionAutoMarkRead(sessionId, enabled: pinned)
  }

  func handleDiffChange(oldDiff: String?, newDiff: String?) {
    guard obs.isDirect, oldDiff == nil, newDiff != nil, layoutConfig == .conversationOnly else {
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
