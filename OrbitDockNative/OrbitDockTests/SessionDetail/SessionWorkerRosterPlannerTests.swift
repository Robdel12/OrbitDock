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
      messagesByWorker: [:],
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
      messagesByWorker: [:],
      timelineMessages: [message]
    )

    #expect(presentation?.reportPreview == "Scout finished and returned a repo summary.")
  }

  @Test func detailPresentationBuildsThreadFeedFromWorkerMessages() {
    let worker = makeWorker(
      id: "worker-thread",
      label: "Gauss",
      status: .completed,
      taskSummary: "Inspect the auth flow",
      resultSummary: "Found the runtime coordinator",
      lastActivityAt: "2026-03-10T11:00:00Z",
      agentType: "worker"
    )

    let presentation = SessionWorkerRosterPlanner.detailPresentation(
      subagents: [worker],
      selectedWorkerID: worker.id,
      toolsByWorker: [:],
      messagesByWorker: [
        worker.id: [
          makeServerMessage(
            id: "worker-user",
            sessionId: worker.id,
            sequence: 1,
            type: .user,
            content: "Inspect the auth flow",
            timestamp: "2026-03-10T11:00:00Z"
          ),
          makeServerMessage(
            id: "worker-assistant",
            sessionId: worker.id,
            sequence: 2,
            type: .assistant,
            content: "The runtime coordinator owns the auth refresh path.",
            timestamp: "2026-03-10T11:00:03Z"
          ),
        ]
      ],
      timelineMessages: []
    )

    #expect(presentation?.threadEntries.count == 2)
    #expect(presentation?.threadEntries.first?.title == "Worker prompt")
    #expect(presentation?.threadEntries.last?.body == "The runtime coordinator owns the auth refresh path.")
  }

  @Test func detailPresentationBuildsConversationTrailFromWorkerLinkedMessages() {
    let worker = makeWorker(
      id: "worker-running",
      label: "Scout",
      status: .running,
      taskSummary: nil,
      resultSummary: nil,
      lastActivityAt: "2026-03-10T11:00:00Z",
      agentType: "explore"
    )

    let spawnMessage = TranscriptMessage(
      id: "spawn-1",
      type: .tool,
      content: "Spawning worker",
      timestamp: Date(timeIntervalSince1970: 1_730_000_010),
      toolName: "task",
      toolInput: [
        "subagent_id": worker.id,
        "prompt": "Inspect the auth layer"
      ],
      rawToolInput: nil,
      toolOutput: nil,
      toolDuration: nil,
      inputTokens: nil,
      outputTokens: nil,
      isError: false,
      isInProgress: true
    )

    let waitMessage = TranscriptMessage(
      id: "wait-1",
      type: .tool,
      content: "Waiting for worker",
      timestamp: Date(timeIntervalSince1970: 1_730_000_100),
      toolName: "task",
      toolInput: [
        "receiver_thread_ids": [worker.id]
      ],
      rawToolInput: nil,
      toolOutput: "Worker found the auth entrypoints and is reporting back.",
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
      messagesByWorker: [:],
      timelineMessages: [spawnMessage, waitMessage]
    )

    #expect(presentation?.assignmentPreview == "Inspect the auth layer")
    #expect(presentation?.conversationEvents.count == 2)
    #expect(presentation?.conversationEvents.first?.title == "Task")
    #expect(presentation?.conversationEvents.last?.summary == "Worker found the auth entrypoints and is reporting back.")
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

  private func makeServerMessage(
    id: String,
    sessionId: String,
    sequence: UInt64,
    type: ServerMessageType,
    content: String,
    timestamp: String
  ) -> ServerMessage {
    let json = """
    {
      "id": "\(id)",
      "session_id": "\(sessionId)",
      "sequence": \(sequence),
      "message_type": "\(type.rawValue)",
      "content": \(content.debugDescription),
      "is_error": false,
      "timestamp": "\(timestamp)"
    }
    """

    let decoder = JSONDecoder()
    return try! decoder.decode(ServerMessage.self, from: Data(json.utf8))
  }
}
