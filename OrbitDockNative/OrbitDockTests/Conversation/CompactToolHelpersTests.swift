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

  @Test func toolTypeFromStringMapsKnownTypes() {
    #expect(CompactToolHelpers.toolTypeFromString("bash") == .bash)
    #expect(CompactToolHelpers.toolTypeFromString("edit") == .edit)
    #expect(CompactToolHelpers.toolTypeFromString("mcp") == .mcp)
    #expect(CompactToolHelpers.toolTypeFromString("unknown") == .generic)
  }

  @Test func displayNameFormatsToolNames() {
    #expect(CompactToolHelpers.displayName(for: "bash") == "Bash")
    #expect(CompactToolHelpers.displayName(for: "edit") == "Edit")
    #expect(CompactToolHelpers.displayName(for: "webfetch") == "Fetch")
    #expect(CompactToolHelpers.displayName(for: "askuserquestion") == "Question")
  }

  @Test func mcpServerNameExtractsServerFromMcpToolName() {
    let message = makeToolMessage(toolName: "mcp__github__create_issue", toolInput: [:])
    #expect(CompactToolHelpers.mcpServerName(for: message) == "github")
  }

  @Test func mcpServerNameReturnsNilForNonMcpTools() {
    let message = makeToolMessage(toolName: "bash", toolInput: [:])
    #expect(CompactToolHelpers.mcpServerName(for: message) == nil)
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

    let content = SharedModelBuilders.expandedToolContent(
      from: message,
      toolName: "TodoWrite"
    )
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

    let content = SharedModelBuilders.expandedToolContent(
      from: message,
      toolName: "TodoWrite"
    )
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

  @Test func compactToolModelCarriesLinkedWorkerIDForWorkerMessages() {
    let message = makeToolMessage(
      toolName: "spawn_agent",
      toolInput: ["receiver_thread_id": "worker-123"]
    )

    let model = SharedModelBuilders.compactToolModel(from: message)

    #expect(model.linkedWorkerID == "worker-123")
  }

  @Test func compactToolModelCarriesLinkedWorkerIDFromTaskPayload() {
    let message = makeToolMessage(
      toolName: "task",
      toolInput: [
        "description": "Inspect the current Swift worker deck UI",
        "subagent_id": "worker-123",
      ]
    )

    let model = SharedModelBuilders.compactToolModel(from: message)

    #expect(model.linkedWorkerID == "worker-123")
  }

  @Test func compactToolModelSurfacesLinkedWorkerIdentityAndResultPreview() {
    let message = makeToolMessage(
      toolName: "wait",
      toolInput: ["receiver_thread_id": "worker-123"]
    )

    let worker = ServerSubagentInfo(
      id: "worker-123",
      agentType: "worker",
      startedAt: "2026-03-11T01:00:00Z",
      endedAt: "2026-03-11T01:02:00Z",
      provider: .codex,
      label: "Wegener",
      status: .completed,
      taskSummary: "Inspect the worker transcript",
      resultSummary: "Worker verified the transcript wiring and returned cleanly.",
      errorSummary: nil,
      parentSubagentId: nil,
      model: nil,
      lastActivityAt: "2026-03-11T01:02:00Z"
    )

    let model = SharedModelBuilders.compactToolModel(
      from: message,
      subagentsByID: [worker.id: worker]
    )

    #expect(model.linkedWorkerID == "worker-123")
    #expect(model.linkedWorkerLabel == "Wegener")
    #expect(model.linkedWorkerStatusText == "Complete")
    #expect(model.subtitle == "Wegener · Complete")
    #expect(model.outputPreview == "Worker verified the transcript wiring and returned cleanly.")
  }

  @Test func compactToolModelMarksFocusedWorkerRows() {
    let message = makeToolMessage(
      toolName: "wait",
      toolInput: ["receiver_thread_id": "worker-123"]
    )

    let focusedModel = SharedModelBuilders.compactToolModel(
      from: message,
      selectedWorkerID: "worker-123"
    )
    let unfocusedModel = SharedModelBuilders.compactToolModel(
      from: message,
      selectedWorkerID: "worker-999"
    )

    #expect(focusedModel.isFocusedWorker)
    #expect(!unfocusedModel.isFocusedWorker)
  }

  @Test func workerEventModelMarksFocusedWorkerRows() {
    let message = makeToolMessage(
      toolName: "wait",
      toolInput: ["receiver_thread_id": "worker-123"]
    )

    let focusedModel = SharedModelBuilders.workerEventModel(
      from: message,
      selectedWorkerID: "worker-123"
    )
    let unfocusedModel = SharedModelBuilders.workerEventModel(
      from: message,
      selectedWorkerID: "worker-999"
    )

    #expect(focusedModel?.isFocusedWorker == true)
    #expect(unfocusedModel?.isFocusedWorker == false)
  }

  @Test func workerEventPreviewUsesCheapSanitizedPrefix() {
    let longOutput = String(repeating: "header\n", count: 200) + "\u{001B}[32mWorker finished cleanly\u{001B}[0m"
    let message = makeToolMessage(
      toolName: "wait",
      toolInput: ["receiver_thread_id": "worker-123"],
      toolOutput: longOutput
    )

    let model = SharedModelBuilders.workerEventModel(from: message)

    #expect(model?.outputPreview?.contains("Worker finished cleanly") == true)
    #expect(model?.outputPreview?.contains("\u{001B}[32m") == false)
  }

  @Test func workerEventModelTreatsHandoffAsRealtimeStructure() {
    let message = makeToolMessage(
      toolName: "handoff",
      toolInput: ["receiver_thread_id": "worker-123"],
      toolOutput: "Passed the renderer polish pass to Wegener."
    )

    let model = SharedModelBuilders.workerEventModel(from: message)

    #expect(model?.toolType == .handoff)
    #expect(model?.summary == "Handoff")
    #expect(model?.subtitle == "Worker · Passed the renderer polish pass to Wegener.")
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
