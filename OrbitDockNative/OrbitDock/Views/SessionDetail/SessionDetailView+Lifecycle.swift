import SwiftUI

extension SessionDetailView {
  func handleDiffChange(oldDiff: String?, newDiff: String?) {
    guard viewModel.handleDiffChange(oldDiff: oldDiff, newDiff: newDiff) else { return }
    withAnimation(Motion.standard) {
      viewModel.showDiffBanner = true
    }
    Task {
      try? await Task.sleep(for: .seconds(8))
      await MainActor.run {
        withAnimation(Motion.standard) {
          viewModel.showDiffBanner = false
        }
      }
    }
  }

  func selectWorkerInPanel(_ workerId: String) {
    guard !workerId.isEmpty else { return }
    viewModel.selectWorkerInPanel(workerId)
  }

  func focusWorkerInDeck(_ workerId: String) {
    guard !workerId.isEmpty else { return }
    showWorkerPanel = true
    viewModel.focusWorkerInDeck(workerId)
  }
}
