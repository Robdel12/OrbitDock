import SwiftUI

extension SessionDetailView {
  func handleReviewTurnCountChange(oldCount: UInt64, newCount: UInt64) {
    _ = viewModel.handleReviewTurnCountChange(oldCount: oldCount, newCount: newCount)
  }

  func handleDiffChange(oldDiff: String?, newDiff: String?) {
    _ = viewModel.handleDiffChange(oldDiff: oldDiff, newDiff: newDiff)
  }

  func selectWorkerInPanel(_ workerId: String) {
    guard !workerId.isEmpty else { return }
    viewModel.worker.select(
      workerId: workerId,
      sessionId: sessionId,
      session: scopedSession,
      layoutConfig: viewModel.layoutConfig
    )
  }

  func focusWorkerInDeck(_ workerId: String) {
    guard !workerId.isEmpty else { return }
    showWorkerPanel = true
    viewModel.worker.focus(
      workerId: workerId,
      sessionId: sessionId,
      session: scopedSession,
      layoutConfig: viewModel.layoutConfig
    )
  }
}
