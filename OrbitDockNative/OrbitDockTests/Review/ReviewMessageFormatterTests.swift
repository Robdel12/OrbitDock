import Foundation
import Testing
@testable import OrbitDock

struct ReviewMessageFormatterTests {
  @Test func formatBuildsStructuredReviewMessageWithDiffSnippetsAndIds() {
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

    let message = ReviewMessageFormatter.format(
      comments: comments,
      model: makeDiffModel()
    )

    #expect(message?.contains("## Code Review Feedback") == true)
    #expect(message?.contains("### Sources/App.swift") == true)
    #expect(message?.contains("### Sources/Feature.swift") == true)
    #expect(message?.contains("**Lines 10–11** [clarity]:") == true)
    #expect(message?.contains("**Line 20** [risk]:") == true)
    #expect(message?.contains("let renamed = helper()") == true)
    #expect(message?.contains("let safeDefault = true") == true)
    #expect(message?.contains("> Please rename this helper") == true)
    #expect(message?.contains("> This needs a safer default") == true)
    #expect(message?.contains("<!-- review-comment-ids: c-1,c-2 -->") == true)
  }

  @Test func extractDiffLinesIncludesTrailingRemovedLineAfterMatchedRange() {
    let lines = ReviewMessageFormatter.extractDiffLines(
      model: makeDiffModel(),
      filePath: "Sources/App.swift",
      lineStart: 10,
      lineEnd: 11
    )

    #expect(lines == """
     func work()
    +let renamed = helper()
    -let oldName = helper()
    """)
  }

  @Test func formatStillBuildsMessageWhenDiffContentIsUnavailable() {
    let comments = [
      makeComment(
        id: "c-1",
        filePath: "Sources/Missing.swift",
        lineStart: 7,
        lineEnd: nil,
        body: "Please add a guard clause",
        tag: nil
      )
    ]

    let message = ReviewMessageFormatter.format(comments: comments, model: nil)

    #expect(message?.contains("### Sources/Missing.swift") == true)
    #expect(message?.contains("> Please add a guard clause") == true)
    #expect(message?.contains("```") == false)
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
            header: "@@ -10,3 +10,3 @@",
            oldStart: 10,
            oldCount: 3,
            newStart: 10,
            newCount: 3,
            lines: [
              DiffLine(type: .context, content: "func work()", oldLineNum: 10, newLineNum: 10, prefix: " "),
              DiffLine(type: .added, content: "let renamed = helper()", oldLineNum: nil, newLineNum: 11, prefix: "+"),
              DiffLine(type: .removed, content: "let oldName = helper()", oldLineNum: 11, newLineNum: nil, prefix: "-"),
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
          )
        ]
      ),
    ])
  }
}
