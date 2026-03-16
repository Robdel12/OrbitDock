import SwiftUI

extension SessionDetailView {
  func handleOnAppear() {
    // Subscription is managed by ContentView via route changes — not here.
    // This only handles view-local state.
    syncSelectedWorker()
  }

  func handleOnDisappear() {
    // Unsubscription is managed by ContentView via route changes — not here.
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
