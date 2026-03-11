import Foundation
import Testing
@testable import OrbitDock

@MainActor
struct SessionWorkerRosterPlannerTests {
  @Test func presentationOrdersActiveWorkersFirstAndBuildsActiveTitle() {
    let presentation = SessionWorkerRosterPlanner.presentation(
      subagents: [
        makeWorker(
          id: "worker-complete",
          label: "Finisher",
          status: .completed,
          taskSummary: nil,
          resultSummary: "Wrapped up the task",
          lastActivityAt: "2026-03-10T10:00:00Z"
        ),
        makeWorker(
          id: "worker-running",
          label: "Scout",
          status: .running,
          taskSummary: "Map the repository",
          resultSummary: nil,
          lastActivityAt: "2026-03-10T11:00:00Z"
        ),
      ]
    )

    #expect(presentation?.title == "Workers · 1 active")
    #expect(presentation?.workers.map(\.id) == ["worker-running", "worker-complete"])
    #expect(presentation?.workers.first?.subtitle == "Map the repository")
    #expect(presentation?.workers.first?.statusLabel == "Running")
  }

  @Test func presentationFallsBackAcrossWorkerTextFields() {
    let presentation = SessionWorkerRosterPlanner.presentation(
      subagents: [
        makeWorker(
          id: "worker-failed",
          label: nil,
          status: .failed,
          taskSummary: nil,
          resultSummary: nil,
          errorSummary: "sandbox denied",
          agentType: "reviewer"
        )
      ]
    )

    let worker = try! #require(presentation?.workers.first)
    #expect(worker.title == "reviewer")
    #expect(worker.subtitle == "sandbox denied")
    #expect(worker.statusLabel == "Failed")
  }

  @Test func preferredSelectionKeepsExistingWorkerWhenStillPresent() {
    let workers = [
      makeWorker(
        id: "worker-running",
        label: "Scout",
        status: .running,
        taskSummary: "Map the repository",
        resultSummary: nil,
        lastActivityAt: "2026-03-10T11:00:00Z"
      ),
      makeWorker(
        id: "worker-complete",
        label: "Finisher",
        status: .completed,
        taskSummary: nil,
        resultSummary: "Wrapped up the task",
        lastActivityAt: "2026-03-10T10:00:00Z"
      ),
    ]

    let selected = SessionWorkerRosterPlanner.preferredSelectedWorkerID(
      currentSelectionID: "worker-complete",
      subagents: workers
    )

    #expect(selected == "worker-complete")
  }

  @Test func preferredSelectionFallsBackToMostRelevantWorker() {
    let workers = [
      makeWorker(
        id: "worker-complete",
        label: "Finisher",
        status: .completed,
        taskSummary: nil,
        resultSummary: "Wrapped up the task",
        lastActivityAt: "2026-03-10T10:00:00Z"
      ),
      makeWorker(
        id: "worker-running",
        label: "Scout",
        status: .running,
        taskSummary: "Map the repository",
        resultSummary: nil,
        lastActivityAt: "2026-03-10T11:00:00Z"
      ),
    ]

    let selected = SessionWorkerRosterPlanner.preferredSelectedWorkerID(
      currentSelectionID: "missing-worker",
      subagents: workers
    )

    #expect(selected == "worker-running")
  }

  @Test func detailPresentationBuildsWorkerAndToolSummary() {
    let worker = makeWorker(
      id: "worker-running",
      label: "Scout",
      status: .running,
      taskSummary: "Map the repository",
      resultSummary: nil,
      lastActivityAt: "2026-03-10T11:00:00Z",
      agentType: "explore"
    )

    let presentation = SessionWorkerRosterPlanner.detailPresentation(
      subagents: [worker],
      selectedWorkerID: worker.id,
      toolsByWorker: [
        worker.id: [
          ServerSubagentTool(
            id: "tool-1",
            toolName: "read",
            summary: "Read the README",
            output: nil,
            isInProgress: true
          )
        ]
      ],
      timelineMessages: []
    )

    #expect(presentation?.title == "Scout")
    #expect(presentation?.statusLabel == "Running")
    #expect(presentation?.tools.first?.toolName == "read")
    #expect(presentation?.detailLines.contains(where: { $0.label == "Role" && $0.value == "Explorer" }) == true)
  }

  @Test func detailPresentationFallsBackToTimelineReportPreview() {
    let worker = makeWorker(
      id: "worker-running",
      label: "Scout",
      status: .running,
      taskSummary: "Map the repository",
      resultSummary: nil,
      lastActivityAt: "2026-03-10T11:00:00Z",
      agentType: "explore"
    )

    let message = TranscriptMessage(
      id: "wait-1",
      type: .tool,
      content: "Waiting for agents",
      timestamp: Date(timeIntervalSince1970: 1_730_000_000),
      toolName: "task",
      toolInput: [
        "receiver_thread_ids": [worker.id]
      ],
      rawToolInput: nil,
      toolOutput: """
      sender: parent-thread
      worker-thread - nickname=Scout - role=explore: Completed(Some(\"Scout finished and returned a repo summary.\"))
      """,
      toolDuration: nil,
      inputTokens: nil,
      outputTokens: nil,
      isError: false,
      isInProgress: false
    )

    let presentation = SessionWorkerRosterPlanner.detailPresentation(
      subagents: [worker],
      selectedWorkerID: worker.id,
      toolsByWorker: [:],
      timelineMessages: [message]
    )

    #expect(presentation?.reportPreview == "Scout finished and returned a repo summary.")
  }

  @Test func presentationReturnsNilWhenThereAreNoWorkers() {
    #expect(SessionWorkerRosterPlanner.presentation(subagents: []) == nil)
  }

  private func makeWorker(
    id: String,
    label: String?,
    status: ServerSubagentStatus?,
    taskSummary: String?,
    resultSummary: String?,
    errorSummary: String? = nil,
    lastActivityAt: String? = nil,
    agentType: String = "agent"
  ) -> ServerSubagentInfo {
    ServerSubagentInfo(
      id: id,
      agentType: agentType,
      startedAt: "2026-03-10T09:00:00Z",
      endedAt: nil,
      provider: .codex,
      label: label,
      status: status,
      taskSummary: taskSummary,
      resultSummary: resultSummary,
      errorSummary: errorSummary,
      parentSubagentId: nil,
      model: nil,
      lastActivityAt: lastActivityAt
    )
  }
}
