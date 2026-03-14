import SwiftUI
@testable import OrbitDock
import Testing

struct ExpandedToolHeaderPlanningTests {
  @Test func editPlanBuildsDiffStatsAndShortPathSubtitle() {
    let model = NativeExpandedToolModel(
      messageID: "tool-1",
      toolColor: .systemBlue,
      iconName: "pencil",
      hasError: false,
      isInProgress: false,
      canCancel: false,
      duration: nil,
      linkedWorkerID: nil,
      family: .file,
      content: .edit(
        filename: "Notes.md",
        path: "/tmp/project/docs/Notes.md",
        additions: 12,
        deletions: 3,
        lines: [],
        isWriteNew: false
      )
    )

    let plan = ExpandedToolHeaderPlanning.plan(for: model)

    guard case let .plain(text, style) = plan.title else {
      Issue.record("Expected plain title plan for edit header")
      return
    }
    #expect(text == "Notes.md")
    guard case .primary = style else {
      Issue.record("Expected primary title style for edit header")
      return
    }
    #expect(plan.subtitle == "project/docs/Notes.md")
    #expect(plan.statsText == "−3 +12")
    guard case let .diff(additions, deletions) = plan.statsTone else {
      Issue.record("Expected diff stats tone for edit header")
      return
    }
    #expect(additions == 12)
    #expect(deletions == 3)
  }

  @Test func todoPlanSummarizesProgressAndActiveCount() {
    let items = [
      NativeTodoItem(content: "Ship login", activeForm: nil, status: .completed),
      NativeTodoItem(content: "Refactor state", activeForm: "Refactoring state", status: .inProgress),
      NativeTodoItem(content: "Write docs", activeForm: nil, status: .pending),
    ]
    let model = NativeExpandedToolModel(
      messageID: "tool-2",
      toolColor: .systemTeal,
      iconName: "checklist",
      hasError: false,
      isInProgress: false,
      canCancel: false,
      duration: nil,
      linkedWorkerID: nil,
      family: .plan,
      content: .todo(title: "Todos", subtitle: "Current pass", items: items, output: nil)
    )

    let plan = ExpandedToolHeaderPlanning.plan(for: model)

    guard case let .plain(text, style) = plan.title else {
      Issue.record("Expected plain title plan for todo header")
      return
    }
    #expect(text == "Todos")
    guard case .toolTint = style else {
      Issue.record("Expected tool-tint title style for todo header")
      return
    }
    #expect(plan.subtitle == "Current pass")
    #expect(plan.statsText == "1/3 done · 1 active")
    guard case .secondary = plan.statsTone else {
      Issue.record("Expected secondary stats tone for todo header")
      return
    }
  }

  @Test func bashPlanKeepsCommandAsStructuredTitle() {
    let model = NativeExpandedToolModel(
      messageID: "tool-3",
      toolColor: .systemOrange,
      iconName: "terminal",
      hasError: false,
      isInProgress: true,
      canCancel: true,
      duration: nil,
      linkedWorkerID: nil,
      family: .shell,
      content: .bash(command: "git status", input: nil, output: nil)
    )

    let plan = ExpandedToolHeaderPlanning.plan(for: model)

    guard case let .bash(command) = plan.title else {
      Issue.record("Expected bash title plan for bash header")
      return
    }
    #expect(command == "git status")
    #expect(plan.subtitle == nil)
    #expect(plan.statsText == nil)
  }
}
