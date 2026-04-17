import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct ReviewCanvasViewModelTests {
  @Test func bindResetsStateWhenSessionIdentityChanges() {
    let sessionA = ServerSessionContext.preview()
    let sessionB = ServerSessionContext.preview()
    let viewModel = ReviewCanvasViewModel(sessionId: "session-a", session: sessionA)

    viewModel.turnDiffs = [ServerTurnDiff(turnId: "turn-1", diff: "diff-a")]
    viewModel.currentDiff = "current"
    viewModel.cumulativeDiff = "cumulative"
    viewModel.reviewComments = [makeReviewComment(id: "comment-a", sessionId: "session-a")]

    viewModel.bind(sessionId: "session-b", session: sessionB)

    #expect(viewModel.currentSessionId == "session-b")
    #expect(viewModel.currentSession === sessionB)
    #expect(viewModel.turnDiffs.isEmpty)
    #expect(viewModel.currentDiff == nil)
    #expect(viewModel.cumulativeDiff == nil)
    #expect(viewModel.reviewComments.isEmpty)
  }

  @Test func bindKeepsStateWhenSessionIdentityIsUnchanged() {
    let session = ServerSessionContext.preview()
    let viewModel = ReviewCanvasViewModel(sessionId: "session-a", session: session)
    let expectedComment = makeReviewComment(id: "comment-a", sessionId: "session-a")

    viewModel.turnDiffs = [ServerTurnDiff(turnId: "turn-1", diff: "diff-a")]
    viewModel.currentDiff = "current"
    viewModel.cumulativeDiff = "cumulative"
    viewModel.reviewComments = [expectedComment]

    viewModel.bind(sessionId: "session-a", session: session)

    #expect(viewModel.turnDiffs.count == 1)
    #expect(viewModel.currentDiff == "current")
    #expect(viewModel.cumulativeDiff == "cumulative")
    #expect(viewModel.reviewComments.count == 1)
    #expect(viewModel.reviewComments.first?.id == expectedComment.id)
  }

  private func makeReviewComment(id: String, sessionId: String) -> ServerReviewComment {
    ServerReviewComment(
      id: id,
      sessionId: sessionId,
      turnId: nil,
      filePath: "Sources/App.swift",
      lineStart: 1,
      lineEnd: nil,
      body: "review",
      tag: nil,
      status: .open,
      createdAt: "",
      updatedAt: nil
    )
  }
}
