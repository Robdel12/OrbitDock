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

  func sendAgentThreadMessage() {
    guard let workerId = viewModel.worker.selectedWorkerId else { return }
    let content = viewModel.worker.messageDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !content.isEmpty, !viewModel.worker.isSendingMessage else { return }

    viewModel.worker.isSendingMessage = true
    viewModel.interaction.lastError = nil

    Task {
      defer {
        viewModel.worker.isSendingMessage = false
      }

      do {
        let result = try await scopedSession.api.sendAgentThreadMessage(
          threadId: workerId,
          content: content
        )
        viewModel.worker.messageDraft = ""
        viewModel.applyConversationMutationRow(result.row)
        if let snapshot = result.sessionDetailSnapshot {
          viewModel.applyDetailPayload(snapshot)
        }
        viewModel.worker.loadDetails(
          sessionId: sessionId,
          session: scopedSession,
          layoutConfig: viewModel.layoutConfig,
          for: workerId
        )
      } catch {
        viewModel.interaction.lastError = String(describing: error)
      }
    }
  }
}
