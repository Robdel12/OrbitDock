import Foundation
@testable import OrbitDock
import Testing

struct CompactToolHelpersTests {
  @Test func compactSingleLineSummaryFlattensWhitespaceAndTruncates() {
    let value = "  first line  \n\n  second    line  "
    let summary = CompactToolHelpers.compactSingleLineSummary(value, maxLength: 10)
    #expect(summary == "first line...")
  }

  @Test func compactSingleLineSummaryReturnsToolWhenEmpty() {
    #expect(CompactToolHelpers.compactSingleLineSummary(" \n\t\r ") == "tool")
  }

  @Test func todoWriteInputRendersStructuredTodoItems() {
    let message = makeToolMessage(
      toolName: "TodoWrite",
      toolInput: [
        "todos": [
          [
            "content": "Add structured todo card",
            "status": "in_progress",
            "activeForm": "Adding structured todo card",
          ],
          [
            "content": "Verify payload parsing",
            "status": "pending",
            "activeForm": "Verifying payload parsing",
          ],
        ],
      ]
    )

    let content = SharedModelBuilders.expandedToolContent(from: message, toolName: "TodoWrite")
    switch content {
      case let .todo(title, subtitle, items, output):
        #expect(title == "Todos")
        #expect(subtitle == "2 items · 1 active")
        #expect(items.count == 2)
        if case .inProgress = items[0].status {} else { Issue.record("Expected first todo status to be in_progress") }
        #expect(items[0].primaryText == "Adding structured todo card")
        if case .pending = items[1].status {} else { Issue.record("Expected second todo status to be pending") }
        #expect(output == nil)
      default:
        Issue.record("Expected structured todo content for TodoWrite input")
    }
  }

  @Test func todoWriteOutputPrefersNewTodosShapeFromClaudeSdk() {
    let output = """
    {"oldTodos":[{"content":"Old item","status":"pending","activeForm":"Old item"}],"newTodos":[{"content":"Done item","status":"completed","activeForm":"Completing done item"}]}
    """
    let message = makeToolMessage(
      toolName: "TodoWrite",
      toolInput: ["todos": []],
      toolOutput: output
    )

    let content = SharedModelBuilders.expandedToolContent(from: message, toolName: "TodoWrite")
    switch content {
      case let .todo(_, subtitle, items, renderedOutput):
        #expect(subtitle == "1 items · 1 done")
        #expect(items.count == 1)
        #expect(items[0].content == "Done item")
        if case .completed = items[0].status {} else { Issue.record("Expected output todo status to be completed") }
        #expect(renderedOutput == nil)
      default:
        Issue.record("Expected TodoWrite output payload to map to todo items")
    }
  }

  @Test func codexServerPrefixedTaskCreateStillClassifiesAsTodo() {
    let message = makeToolMessage(
      toolName: "planner:taskcreate",
      toolInput: ["subject": "Ship polished todo UI", "status": "pending"]
    )

    #expect(CompactToolHelpers.summary(for: message) == "Ship polished todo UI")
    #expect(ToolGlyphInfo.from(message: message).symbol == "checklist")
  }

  private func makeToolMessage(
    toolName: String,
    toolInput: [String: Any],
    toolOutput: String? = nil
  ) -> TranscriptMessage {
    TranscriptMessage(
      id: UUID().uuidString,
      type: .tool,
      content: "",
      timestamp: Date(),
      toolName: toolName,
      toolInput: toolInput,
      toolOutput: toolOutput,
      toolDuration: nil,
      inputTokens: nil,
      outputTokens: nil,
      isError: false,
      isInProgress: false
    )
  }
}
