import SwiftUI

extension SessionDetailView {
  func handleOnAppear() {
    // Subscription is managed by ContentView via route changes — not here.
    // This only handles view-local state.
    viewModel.syncSelectedWorker()
  }

  func handleOnDisappear() {
    // Unsubscription is managed by ContentView via route changes — not here.
  }

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

  func loadSelectedWorkerTools(for workerId: String? = nil) {
    guard showWorkerPanel else { return }
    viewModel.loadSelectedWorkerTools(for: workerId)
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
