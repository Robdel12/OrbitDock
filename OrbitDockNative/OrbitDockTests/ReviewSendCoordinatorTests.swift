import Foundation
@testable import OrbitDock
import Testing

struct ReviewSendCoordinatorTests {
  @Test func makePlanBuildsMessageRoundAndResolutionList() {
    let comments = [
      makeComment(
        id: "c-1",
        filePath: "Sources/App.swift",
        lineStart: 10,
        lineEnd: 11,
        body: "Please rename this helper",
        tag: .clarity
      ),
      makeComment(
        id: "c-2",
        filePath: "Sources/Feature.swift",
        lineStart: 20,
        lineEnd: nil,
        body: "This needs a safer default",
        tag: .risk
      ),
    ]

    let plan = ReviewSendCoordinator.makePlan(
      openComments: comments,
      selectedCommentIds: ["c-2"],
      diffModel: makeDiffModel(),
      turnDiffs: [
        ServerTurnDiff(turnId: "turn-1", diff: "diff-a"),
        ServerTurnDiff(turnId: "turn-2", diff: "diff-b"),
      ],
      sentAt: Date(timeIntervalSince1970: 123)
    )

    #expect(plan != nil)
    #expect(plan?.commentIdsToResolve == ["c-2"])
    #expect(plan?.reviewRound.sentAt == Date(timeIntervalSince1970: 123))
    #expect(plan?.reviewRound.turnDiffCountAtSend == 2)
    #expect(plan?.reviewRound.reviewedFilePaths == ["Sources/Feature.swift"])
    #expect(plan?.reviewRound.commentCount == 1)
    #expect(plan?.message.contains("## Code Review Feedback") == true)
    #expect(plan?.message.contains("### Sources/Feature.swift") == true)
    #expect(plan?.message.contains("> This needs a safer default") == true)
    #expect(plan?.message.contains("<!-- review-comment-ids: c-2 -->") == true)
  }

  @Test func roundTrackerDerivesPendingAndProgressStates() {
    var state = ReviewRoundTrackerState()
    state.record(
      ReviewRound(
        sentAt: Date(timeIntervalSince1970: 200),
        turnDiffCountAtSend: 1,
        reviewedFilePaths: ["Sources/App.swift"],
        commentCount: 2
      )
    )

    let pendingBanner = ReviewRoundTracker.bannerState(
      state: state,
      turnDiffs: [ServerTurnDiff(turnId: "turn-1", diff: "diff-a")]
    )

    if case .pending? = pendingBanner?.tone {
      #expect(true)
    } else {
      Issue.record("Expected pending review banner tone")
    }
    #expect(pendingBanner?.title == "Review sent")

    let progressTurnDiffs = [
      ServerTurnDiff(turnId: "turn-1", diff: "diff-a"),
      ServerTurnDiff(turnId: "turn-2", diff: """
      diff --git a/Sources/App.swift b/Sources/App.swift
      --- a/Sources/App.swift
      +++ b/Sources/App.swift
      @@
      +updated
      """),
    ]

    let progressBanner = ReviewRoundTracker.bannerState(
      state: state,
      turnDiffs: progressTurnDiffs
    )
    let addressed = ReviewRoundTracker.addressedFilePaths(
      state: state,
      turnDiffs: progressTurnDiffs
    )

    if case .progress? = progressBanner?.tone {
      #expect(true)
    } else {
      Issue.record("Expected progress review banner tone")
    }
    #expect(progressBanner?.title == "1 of 1 reviewed file updated")
    #expect(addressed == ["Sources/App.swift"])
    #expect(
      ReviewRoundTracker.addressedFileStatus(
        filePath: "Sources/App.swift",
        state: state,
        turnDiffs: progressTurnDiffs
      ) == true
    )

    state.dismissBanner()
    #expect(
      ReviewRoundTracker.bannerState(
        state: state,
        turnDiffs: progressTurnDiffs
      ) == nil
    )
  }

  private func makeComment(
    id: String,
    filePath: String,
    lineStart: UInt32,
    lineEnd: UInt32?,
    body: String,
    tag: ServerReviewCommentTag?
  ) -> ServerReviewComment {
    ServerReviewComment(
      id: id,
      sessionId: "session-1",
      turnId: "turn-1",
      filePath: filePath,
      lineStart: lineStart,
      lineEnd: lineEnd,
      body: body,
      tag: tag,
      status: .open,
      createdAt: "2026-03-10T00:00:00Z",
      updatedAt: nil
    )
  }

  private func makeDiffModel() -> DiffModel {
    DiffModel(files: [
      FileDiff(
        id: "Sources/App.swift",
        oldPath: "Sources/App.swift",
        newPath: "Sources/App.swift",
        changeType: .modified,
        hunks: [
          DiffHunk(
            id: 0,
            header: "@@ -10,2 +10,2 @@",
            oldStart: 10,
            oldCount: 2,
            newStart: 10,
            newCount: 2,
            lines: [
              DiffLine(type: .context, content: "func work()", oldLineNum: 10, newLineNum: 10, prefix: " "),
              DiffLine(type: .added, content: "let renamed = helper()", oldLineNum: nil, newLineNum: 11, prefix: "+"),
            ]
          ),
        ]
      ),
      FileDiff(
        id: "Sources/Feature.swift",
        oldPath: "Sources/Feature.swift",
        newPath: "Sources/Feature.swift",
        changeType: .modified,
        hunks: [
          DiffHunk(
            id: 1,
            header: "@@ -20,1 +20,1 @@",
            oldStart: 20,
            oldCount: 1,
            newStart: 20,
            newCount: 1,
            lines: [
              DiffLine(type: .added, content: "let safeDefault = true", oldLineNum: nil, newLineNum: 20, prefix: "+"),
            ]
          ),
        ]
      ),
    ])
  }
}
