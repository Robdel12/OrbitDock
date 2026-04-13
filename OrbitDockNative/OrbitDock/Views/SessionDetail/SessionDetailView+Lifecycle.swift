import SwiftUI

extension SessionDetailView {
  func handleReviewTurnCountChange(oldCount: UInt64, newCount: UInt64) {
    guard viewModel.handleReviewTurnCountChange(oldCount: oldCount, newCount: newCount) else { return }
    presentDiffBanner()
  }

  func handleDiffChange(oldDiff: String?, newDiff: String?) {
    guard viewModel.handleDiffChange(oldDiff: oldDiff, newDiff: newDiff) else { return }
    presentDiffBanner()
  }

  private func presentDiffBanner() {
    withAnimation(Motion.standard) {
      viewModel.review.showDiffBanner = true
    }
    Task {
      try? await Task.sleep(for: .seconds(8))
      await MainActor.run {
        withAnimation(Motion.standard) {
          viewModel.review.showDiffBanner = false
        }
      }
    }
  }

  func selectWorkerInPanel(_ workerId: String) {
    guard !workerId.isEmpty else { return }
    viewModel.worker.select(
      workerId: workerId,
      sessionId: sessionId,
      sessionStore: scopedServerState,
      layoutConfig: viewModel.layoutConfig
    )
  }

  func focusWorkerInDeck(_ workerId: String) {
    guard !workerId.isEmpty else { return }
    showWorkerPanel = true
    viewModel.worker.focus(
      workerId: workerId,
      sessionId: sessionId,
      sessionStore: scopedServerState,
      layoutConfig: viewModel.layoutConfig
    )
  }
}
