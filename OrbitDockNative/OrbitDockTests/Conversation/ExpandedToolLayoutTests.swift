import CoreGraphics
import Foundation
@testable import OrbitDock
import Testing

struct ExpandedToolLayoutTests {
  @Test func structuredPayloadEntriesFlattenNestedJSON() {
    let payload = """
    {
      "command": "bash",
      "options": {
        "cwd": "/tmp/demo",
        "retry": true
      },
      "files": ["a.txt", "b.txt"]
    }
    """

    let entries = ExpandedToolLayout.structuredPayloadEntries(from: payload)

    #expect(entries == [
      .init(keyPath: "command", value: "\"bash\""),
      .init(keyPath: "files", value: "[\"a.txt\", \"b.txt\"]"),
      .init(keyPath: "options.cwd", value: "\"/tmp/demo\""),
      .init(keyPath: "options.retry", value: "true"),
    ])
  }

  @Test func askUserQuestionItemsParseHeadersAndOptions() {
    let payload = """
    {
      "questions": [
        {
          "header": "Choice",
          "question": "How should we continue?",
          "options": [
            { "label": "Keep going", "description": "Continue the current plan" },
            { "label": "Pause" }
          ]
        }
      ]
    }
    """

    let items = ExpandedToolLayout.askUserQuestionItems(from: payload)

    #expect(items == [
      .init(
        header: "Choice",
        question: "How should we continue?",
        options: [
          .init(label: "Keep going", description: "Continue the current plan"),
          .init(label: "Pause", description: nil),
        ]
      )
    ])
  }

  @Test func diffGutterMetricsReserveColumnsForBothLineNumbers() {
    let lines = [
      DiffLine(type: .context, content: "let a = 1", oldLineNum: 9, newLineNum: 9, prefix: " "),
      DiffLine(type: .added, content: "let b = 2", oldLineNum: nil, newLineNum: 123, prefix: "+"),
    ]

    let metrics = ExpandedToolLayout.diffGutterMetrics(for: lines)

    #expect(metrics.oldLineNumberX != nil)
    #expect(metrics.newLineNumberX != nil)
    #expect(metrics.newLineNumberWidth >= metrics.oldLineNumberWidth)
    #expect(metrics.codeX > metrics.prefixX)
  }

  @Test func payloadSectionPlanPrefersQuestionAndStructuredParsing() {
    let questionPayload = """
    {
      "questions": [
        {
          "header": "Choice",
          "question": "How should we continue?",
          "options": [{ "label": "Keep going" }]
        }
      ]
    }
    """

    let questionPlan = ExpandedToolRenderPlanning.payloadSectionPlan(
      title: "INPUT",
      payload: questionPayload,
      toolName: "question"
    )
    #expect(questionPlan?.title == "INPUT")
    #expect(questionPlan?.content == .askUserQuestions([
      .init(
        header: "Choice",
        question: "How should we continue?",
        options: [.init(label: "Keep going", description: nil)]
      )
    ]))

    let jsonPayload = """
    {
      "command": "bash",
      "options": { "cwd": "/tmp/demo" }
    }
    """
    let jsonPlan = ExpandedToolRenderPlanning.payloadSectionPlan(
      title: "OUTPUT",
      payload: jsonPayload
    )
    #expect(jsonPlan?.content == .structuredEntries([
      .init(keyPath: "command", value: "\"bash\""),
      .init(keyPath: "options.cwd", value: "\"/tmp/demo\""),
    ]))
  }

  @Test func todoRowMetricsProduceStableBadgeAndRowSizing() {
    let item = NativeTodoItem(
      content: "Write the integration tests",
      activeForm: "Writing the integration tests",
      status: .inProgress
    )

    let metrics = ExpandedToolRenderPlanning.todoRowMetrics(for: item, contentWidth: 320)

    #expect(metrics.statusText == "IN PROGRESS")
    #expect(metrics.iconName == "arrow.triangle.2.circlepath")
    #expect(metrics.badgeWidth >= ExpandedToolLayout.todoBadgeMinWidth)
    #expect(metrics.textWidth > 0)
    #expect(metrics.primaryHeight >= ExpandedToolLayout.contentLineHeight)
    #expect(metrics.rowHeight > ExpandedToolLayout.todoBadgeHeight)
  }
}
