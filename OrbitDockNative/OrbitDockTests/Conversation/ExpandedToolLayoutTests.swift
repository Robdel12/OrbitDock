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

    #expect(items?.count == 1)
    if let item = items?.first {
      #expect(item.header == "Choice")
      #expect(item.question == "How should we continue?")
      #expect(item.options.count == 2)
      #expect(item.options.first?.label == "Keep going")
      #expect(item.options.first?.description == "Continue the current plan")
      #expect(item.options.last?.label == "Pause")
      #expect(item.options.last?.description == nil)
    } else {
      Issue.record("Expected a parsed ask-user question item")
    }
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
    switch questionPlan?.content {
      case let .askUserQuestions(items):
        #expect(items.count == 1)
        if let item = items.first {
          #expect(item.header == "Choice")
          #expect(item.question == "How should we continue?")
          #expect(item.options.count == 1)
          #expect(item.options.first?.label == "Keep going")
          #expect(item.options.first?.description == nil)
        } else {
          Issue.record("Expected a parsed ask-user question item")
        }
      default:
        Issue.record("Expected question payload to parse as ask-user questions")
    }

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
    switch jsonPlan?.content {
      case let .structuredEntries(entries):
        #expect(entries.count == 2)
        #expect(entries.first?.keyPath == "command")
        #expect(entries.first?.value == "\"bash\"")
        #expect(entries.last?.keyPath == "options.cwd")
        #expect(entries.last?.value == "\"/tmp/demo\"")
      default:
        Issue.record("Expected JSON payload to parse as structured entries")
    }
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
