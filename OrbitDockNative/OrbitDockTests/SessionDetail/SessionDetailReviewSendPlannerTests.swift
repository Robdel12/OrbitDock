import Foundation
@testable import OrbitDock
import Testing

struct SessionDetailReviewSendPlannerTests {
  @Test func makePlanBuildsMessageForSelectedOpenComments() {
    let comments = [
      makeComment(
        id: "c-1",
        filePath: "Sources/App.swift",
        lineStart: 10,
        lineEnd: 11,
        body: "Please rename this helper",
        status: .open
      ),
      makeComment(
        id: "c-2",
        filePath: "Sources/Feature.swift",
        lineStart: 20,
        body: "This needs a safer default",
        status: .open
      ),
      makeComment(
        id: "c-3",
        filePath: "Sources/Ignore.swift",
        lineStart: 30,
        body: "Already resolved",
        status: .resolved
      ),
    ]

    let plan = SessionDetailReviewSendPlanner.makePlan(
      reviewComments: comments,
      selectedCommentIds: ["c-1"],
      turnDiffs: [makeTurnDiff(diff: diffForAppFile())],
      currentDiff: diffForFeatureFile()
    )

    #expect(plan?.commentIdsToResolve == ["c-1"])
    #expect(plan?.message.contains("### Sources/App.swift") == true)
    #expect(plan?.message.contains("Please rename this helper") == true)
    #expect(plan?.message.contains("### Sources/Feature.swift") == false)
    #expect(plan?.message.contains("Already resolved") == false)
    #expect(plan?.message.contains("let renamed = helper()") == true)
  }

  @Test func makePlanSendsAllOpenCommentsWhenNothingIsSelected() {
    let comments = [
      makeComment(
        id: "c-1",
        filePath: "Sources/App.swift",
        lineStart: 10,
        lineEnd: 11,
        body: "Please rename this helper",
        status: .open
      ),
      makeComment(
        id: "c-2",
        filePath: "Sources/Feature.swift",
        lineStart: 20,
        body: "This needs a safer default",
        status: .open
      ),
    ]

    let plan = SessionDetailReviewSendPlanner.makePlan(
      reviewComments: comments,
      selectedCommentIds: [],
      turnDiffs: [makeTurnDiff(diff: diffForAppFile())],
      currentDiff: diffForFeatureFile()
    )

    #expect(plan?.commentIdsToResolve == ["c-1", "c-2"])
    #expect(plan?.message.contains("### Sources/App.swift") == true)
    #expect(plan?.message.contains("### Sources/Feature.swift") == true)
    #expect(plan?.message.contains("let safeDefault = true") == true)
  }

  @Test func makeDiffModelDoesNotDuplicateCurrentSnapshotWhenItMatchesLastTurnDiff() {
    let diff = diffForAppFile()

    let model = SessionDetailReviewSendPlanner.makeDiffModel(
      turnDiffs: [makeTurnDiff(diff: diff)],
      currentDiff: diff
    )

    #expect(model?.files.count == 1)
    #expect(model?.files.first?.newPath == "Sources/App.swift")
  }

  private func makeComment(
    id: String,
    filePath: String,
    lineStart: UInt32,
    lineEnd: UInt32? = nil,
    body: String,
    status: ServerReviewCommentStatus
  ) -> ServerReviewComment {
    ServerReviewComment(
      id: id,
      sessionId: "session-1",
      turnId: "turn-1",
      filePath: filePath,
      lineStart: lineStart,
      lineEnd: lineEnd,
      body: body,
      tag: nil,
      status: status,
      createdAt: "2026-03-10T00:00:00Z",
      updatedAt: nil
    )
  }

  private func makeTurnDiff(diff: String) -> ServerTurnDiff {
    ServerTurnDiff(
      turnId: "turn-1",
      diff: diff,
      inputTokens: 0,
      outputTokens: 0,
      cachedTokens: 0,
      contextWindow: nil,
      snapshotKind: nil
    )
  }

  private func diffForAppFile() -> String {
    """
    diff --git a/Sources/App.swift b/Sources/App.swift
    --- a/Sources/App.swift
    +++ b/Sources/App.swift
    @@ -10,2 +10,2 @@
     func work()
    -let oldName = helper()
    +let renamed = helper()
    """
  }

  private func diffForFeatureFile() -> String {
    """
    diff --git a/Sources/Feature.swift b/Sources/Feature.swift
    --- a/Sources/Feature.swift
    +++ b/Sources/Feature.swift
    @@ -20,1 +20,1 @@
    +let safeDefault = true
    """
  }
}
