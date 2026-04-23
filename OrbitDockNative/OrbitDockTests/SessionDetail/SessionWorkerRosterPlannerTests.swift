import Foundation
@testable import OrbitDock
import Testing

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

    #expect(presentation?.title == "Workers")
    #expect(presentation?.summary == "1 active · 1 complete")
    #expect(presentation?.detailPrompt == "Keep an eye on live workers here while the conversation stays in front.")
    #expect(presentation?.workers.map(\.id) == ["worker-running", "worker-complete"])
    #expect(presentation?.workers.first?.subtitle == "Map the repository")
    #expect(presentation?.workers.first?.statusLabel == "Running")
  }

  @Test func presentationFallsBackAcrossWorkerTextFields() throws {
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
        ),
      ]
    )

    let worker = try #require(presentation?.workers.first)
    #expect(worker.title == "Reviewer")
    #expect(worker.subtitle == "sandbox denied")
    #expect(worker.statusLabel == "Failed")
    #expect(presentation?.summary == "1 needs review")
  }

  @Test func presentationTreatsInterruptedWorkersAsActiveWithoutFlatteningStatus() throws {
    let presentation = SessionWorkerRosterPlanner.presentation(
      subagents: [
        makeWorker(
          id: "worker-interrupted",
          label: "Scout",
          status: .interrupted,
          taskSummary: "Resume after interruption",
          resultSummary: nil,
          lastActivityAt: "2026-03-10T11:30:00Z"
        ),
      ]
    )

    let worker = try #require(presentation?.workers.first)
    #expect(worker.statusLabel == "Interrupted")
    #expect(worker.isActive)
    #expect(presentation?.summary == "1 active")
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
          ),
        ],
      ],
      messagesByWorker: [:],
      timelineEntries: []
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

    let presentation = SessionWorkerRosterPlanner.detailPresentation(
      subagents: [worker],
      selectedWorkerID: worker.id,
      toolsByWorker: [:],
      messagesByWorker: [:],
      timelineEntries: [
        makeToolEntry(
          id: "wait-1",
          sessionId: worker.id,
          sequence: 1,
          status: .completed,
          title: "task",
          summary: "Waiting for agents",
          startedAt: "2026-03-10T11:00:00Z",
          inputDisplay: #"{"receiver_thread_id":"\#(worker.id)"}"#,
          outputDisplay: """
          sender: parent-thread
          worker-thread - nickname=Scout - role=explore: Completed(Some(\"Scout finished and returned a repo summary.\"))
          """
        ),
      ]
    )

    #expect(presentation?.reportPreview == "Scout finished and returned a repo summary.")
  }

  @Test func detailPresentationUsesWorkerRowsForAssignmentFallback() {
    let worker = makeWorker(
      id: "worker-direct",
      label: "Ada",
      status: .running,
      taskSummary: nil,
      resultSummary: nil,
      lastActivityAt: "2026-03-10T11:00:00Z",
      agentType: "worker"
    )

    let presentation = SessionWorkerRosterPlanner.detailPresentation(
      subagents: [worker],
      selectedWorkerID: worker.id,
      toolsByWorker: [:],
      messagesByWorker: [:],
      timelineEntries: [
        makeWorkerEntry(
          id: "worker-row-1",
          sessionId: worker.id,
          sequence: 1,
          workerId: worker.id,
          title: "Worker started",
          operation: "Spawned worker",
          status: .running,
          taskSummary: "Inspect auth flow"
        ),
      ]
    )

    #expect(presentation?.assignmentPreview == "Inspect auth flow")
    #expect(presentation?.conversationEvents.first?.title == "Spawned worker")
    #expect(presentation?.conversationEvents.first?.statusLabel == "Live")
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
          makeRowEntry(
            id: "worker-user",
            sessionId: worker.id,
            sequence: 1,
            rowType: .user,
            content: "Inspect the auth flow"
          ),
          makeRowEntry(
            id: "worker-assistant",
            sessionId: worker.id,
            sequence: 2,
            rowType: .assistant,
            content: "The runtime coordinator owns the auth refresh path."
          ),
        ],
      ],
      timelineEntries: []
    )

    #expect(presentation?.threadEntries.count == 2)
    // Typed .user rows show up as "Worker prompt" in the thread feed.
    #expect(presentation?.threadEntries.first?.title == "Worker prompt")
    #expect(presentation?.threadEntries.last?.body
      .contains("The runtime coordinator owns the auth refresh path.") == true)
  }

  @Test func agentThreadPresentationOrdersActiveThreadsFirst() throws {
    let running = makeAgentThread(
      id: "thread-running",
      label: "Scout",
      status: "running",
      taskSummary: "Inspect the auth flow",
      resultSummary: nil,
      freshness: "pollable",
      acceptsUserInput: true,
      interjectionMode: "parent_mediated",
      lastActivityAt: "2026-03-10T12:00:00Z"
    )
    let completed = makeAgentThread(
      id: "thread-complete",
      label: "Finisher",
      status: "completed",
      taskSummary: nil,
      resultSummary: "Returned findings",
      freshness: "final_only",
      acceptsUserInput: false,
      interjectionMode: "none",
      lastActivityAt: "2026-03-10T11:00:00Z"
    )

    let presentation = try #require(SessionWorkerRosterPlanner.presentation(agentThreads: [completed, running]))

    #expect(presentation.title == "Agent Threads")
    #expect(presentation.summary == "1 active · 1 complete")
    #expect(presentation.workers.map(\.id) == ["thread-running", "thread-complete"])
    #expect(presentation.workers.first?.subtitle == "Inspect the auth flow")
  }

  @Test func agentThreadDetailSurfacesTranscriptAndInputCapability() throws {
    let thread = makeAgentThread(
      id: "thread-running",
      label: "Scout",
      status: "running",
      taskSummary: "Inspect the auth flow",
      resultSummary: nil,
      freshness: "pollable",
      acceptsUserInput: true,
      interjectionMode: "parent_mediated",
      lastActivityAt: "2026-03-10T12:00:00Z"
    )
    let rows = [
      makeRowEntry(
        id: "thread-user",
        sessionId: "session-1",
        sequence: 1,
        rowType: .user,
        content: "Inspect the auth flow"
      ),
      makeRowEntry(
        id: "thread-assistant",
        sessionId: "session-1",
        sequence: 2,
        rowType: .assistant,
        content: "The runtime coordinator owns the auth refresh path."
      ),
    ]
    let page = ServerAgentThreadConversationPage(
      sessionId: "session-1",
      threadId: thread.id,
      rows: rows,
      totalRowCount: UInt64(rows.count),
      hasMoreBefore: false,
      oldestSequence: rows.first?.sequence,
      newestSequence: rows.last?.sequence,
      freshness: .pollable
    )

    let presentation = try #require(SessionWorkerRosterPlanner.detailPresentation(
      agentThreads: [thread],
      selectedWorkerID: thread.id,
      pageByThread: [thread.id: page],
      subagents: []
    ))

    #expect(presentation.title == "Scout")
    #expect(presentation.transcriptStatusLabel == "Refreshable")
    #expect(presentation.canSendMessage)
    #expect(presentation.messageModeLabel == "Ask parent to redirect")
    #expect(presentation.conversationRows.map(\.id) == ["thread-user", "thread-assistant"])
    #expect(presentation.capabilities.contains(where: { $0.label == "Input" && $0.value == "Ask parent to redirect" }))
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

    let presentation = SessionWorkerRosterPlanner.detailPresentation(
      subagents: [worker],
      selectedWorkerID: worker.id,
      toolsByWorker: [:],
      messagesByWorker: [:],
      timelineEntries: [
        makeToolEntry(
          id: "spawn-1",
          sessionId: worker.id,
          sequence: 1,
          status: .running,
          title: "task",
          summary: "Spawning worker",
          startedAt: "2026-03-10T11:00:10Z",
          inputDisplay: #"{"subagent_id":"\#(worker.id)","prompt":"Inspect the auth layer"}"#,
          outputDisplay: nil
        ),
        makeToolEntry(
          id: "wait-1",
          sessionId: worker.id,
          sequence: 2,
          status: .completed,
          title: "task",
          summary: "Waiting for worker",
          startedAt: "2026-03-10T11:01:40Z",
          inputDisplay: #"{"receiver_thread_id":"\#(worker.id)"}"#,
          outputDisplay: "Worker found the auth entrypoints and is reporting back."
        ),
      ]
    )

    #expect(presentation?.assignmentPreview == "Inspect the auth layer")
    #expect(presentation?.conversationEvents.count == 2)
    #expect(presentation?.conversationEvents.first?.title == "Agent")
    #expect(presentation?.conversationEvents.last?
      .summary == "Worker found the auth entrypoints and is reporting back.")
  }

  @Test func detailPresentationSurfacesGroupedCommandFailuresInsteadOfFlatteningToLive() {
    let worker = makeWorker(
      id: "worker-grouped-failure",
      label: "Scout",
      status: .running,
      taskSummary: "Inspect command failures",
      resultSummary: nil,
      lastActivityAt: "2026-03-10T11:00:00Z",
      agentType: "worker"
    )

    let groupedFailure = ServerConversationRowEntry(
      sessionId: worker.id,
      sequence: 1,
      turnId: nil,
      turnStatus: .active,
      row: .activityGroup(ServerConversationActivityGroupRow(
        id: "group:command-1",
        groupKind: .toolBlock,
        title: "1 previous action",
        subtitle: nil,
        summary: "Run command",
        childCount: 1,
        children: [
          .tool(makeToolRow(
            id: "tool-1",
            sessionId: worker.id,
            sequence: 1,
            status: .completed,
            title: "task",
            summary: "Run command",
            startedAt: "2026-03-10T11:00:00Z",
            inputDisplay: #"{"subagent_id":"\#(worker.id)"}"#,
            outputDisplay: "Command failed"
          )),
        ],
        turnId: nil,
        groupingKey: nil,
        status: .failed,
        family: .shell,
        renderHints: ServerConversationRenderHints()
      ))
    )

    let presentation = SessionWorkerRosterPlanner.detailPresentation(
      subagents: [worker],
      selectedWorkerID: worker.id,
      toolsByWorker: [:],
      messagesByWorker: [:],
      timelineEntries: [groupedFailure]
    )

    #expect(presentation?.conversationEvents.first?.statusLabel == "Error")
  }

  @Test func detailPresentationPrefersOrderedShellPreviewForInterleavedOutput() {
    let worker = makeWorker(
      id: "worker-shell",
      label: "Scout",
      status: .running,
      taskSummary: "Inspect shell output",
      resultSummary: nil,
      lastActivityAt: "2026-03-10T11:00:00Z",
      agentType: "worker"
    )

    let presentation = SessionWorkerRosterPlanner.detailPresentation(
      subagents: [worker],
      selectedWorkerID: worker.id,
      toolsByWorker: [:],
      messagesByWorker: [
        worker.id: [
          makeShellCommandEntry(
            id: "shell-1",
            sessionId: worker.id,
            sequence: 1,
            title: "Run migration check",
            command: "orbitdock migrate --check",
            stdout: "stdout-1\nstdout-2",
            stderr: "stderr-1",
            outputPreview: "stdout-1\nstderr-1\nstdout-2"
          ),
        ],
      ],
      timelineEntries: []
    )

    #expect(presentation?.threadEntries.first?.body == "stdout-1\nstderr-1\nstdout-2")
  }

  @Test func detailPresentationBuildsRelatedWorkerNavigation() {
    let parent = makeWorker(
      id: "worker-parent",
      label: "Coordinator",
      status: .running,
      taskSummary: "Coordinate the sweep",
      resultSummary: nil,
      lastActivityAt: "2026-03-10T11:05:00Z",
      agentType: "planner"
    )
    let child = makeWorker(
      id: "worker-child",
      label: "Scout",
      status: .completed,
      taskSummary: "Inspect auth",
      resultSummary: "Returned findings",
      lastActivityAt: "2026-03-10T11:10:00Z",
      agentType: "explore",
      parentSubagentId: parent.id
    )
    let sibling = makeWorker(
      id: "worker-sibling",
      label: "Reviewer",
      status: .running,
      taskSummary: "Review patch",
      resultSummary: nil,
      lastActivityAt: "2026-03-10T11:11:00Z",
      agentType: "reviewer",
      parentSubagentId: child.id
    )

    let presentation = SessionWorkerRosterPlanner.detailPresentation(
      subagents: [parent, child, sibling],
      selectedWorkerID: child.id,
      toolsByWorker: [:],
      messagesByWorker: [:],
      timelineEntries: []
    )

    #expect(presentation?.relatedWorkers.map(\.id) == [parent.id, sibling.id])
    #expect(presentation?.relatedWorkers.first?.relationshipLabel == "Parent worker")
    #expect(presentation?.relatedWorkers.last?.relationshipLabel == "Child worker")
  }

  @Test func presentationReturnsNilWhenThereAreNoWorkers() {
    #expect(SessionWorkerRosterPlanner.presentation(subagents: []) == nil)
  }

  @Test func presentationLimitsInactiveWorkersToRecentArchivedSlice() {
    let workers = [
      makeWorker(
        id: "worker-running",
        label: "Scout",
        status: .running,
        taskSummary: "Map the repository",
        resultSummary: nil,
        lastActivityAt: "2026-03-10T12:00:00Z"
      ),
      makeWorker(
        id: "worker-complete-1",
        label: "Finisher 1",
        status: .completed,
        taskSummary: nil,
        resultSummary: "Wrapped up",
        lastActivityAt: "2026-03-10T11:59:00Z"
      ),
      makeWorker(
        id: "worker-complete-2",
        label: "Finisher 2",
        status: .completed,
        taskSummary: nil,
        resultSummary: "Wrapped up",
        lastActivityAt: "2026-03-10T11:58:00Z"
      ),
      makeWorker(
        id: "worker-complete-3",
        label: "Finisher 3",
        status: .completed,
        taskSummary: nil,
        resultSummary: "Wrapped up",
        lastActivityAt: "2026-03-10T11:57:00Z"
      ),
      makeWorker(
        id: "worker-complete-4",
        label: "Finisher 4",
        status: .completed,
        taskSummary: nil,
        resultSummary: "Wrapped up",
        lastActivityAt: "2026-03-10T11:56:00Z"
      ),
      makeWorker(
        id: "worker-complete-5",
        label: "Finisher 5",
        status: .completed,
        taskSummary: nil,
        resultSummary: "Wrapped up",
        lastActivityAt: "2026-03-10T11:55:00Z"
      ),
    ]

    let presentation = SessionWorkerRosterPlanner.presentation(subagents: workers)

    #expect(presentation?.workers.map(\.id) == [
      "worker-running",
      "worker-complete-1",
      "worker-complete-2",
      "worker-complete-3",
      "worker-complete-4",
    ])
    #expect(presentation?.summary == "1 active · 5 complete · 1 archived")
  }

  @Test func preferredSelectionDropsArchivedWorkerAndFallsBackToVisibleWorker() {
    let workers = [
      makeWorker(
        id: "worker-running",
        label: "Scout",
        status: .running,
        taskSummary: "Map the repository",
        resultSummary: nil,
        lastActivityAt: "2026-03-10T12:00:00Z"
      ),
      makeWorker(
        id: "worker-complete-1",
        label: "Finisher 1",
        status: .completed,
        taskSummary: nil,
        resultSummary: "Wrapped up",
        lastActivityAt: "2026-03-10T11:59:00Z"
      ),
      makeWorker(
        id: "worker-complete-2",
        label: "Finisher 2",
        status: .completed,
        taskSummary: nil,
        resultSummary: "Wrapped up",
        lastActivityAt: "2026-03-10T11:58:00Z"
      ),
      makeWorker(
        id: "worker-complete-3",
        label: "Finisher 3",
        status: .completed,
        taskSummary: nil,
        resultSummary: "Wrapped up",
        lastActivityAt: "2026-03-10T11:57:00Z"
      ),
      makeWorker(
        id: "worker-complete-4",
        label: "Finisher 4",
        status: .completed,
        taskSummary: nil,
        resultSummary: "Wrapped up",
        lastActivityAt: "2026-03-10T11:56:00Z"
      ),
      makeWorker(
        id: "worker-complete-5",
        label: "Finisher 5",
        status: .completed,
        taskSummary: nil,
        resultSummary: "Wrapped up",
        lastActivityAt: "2026-03-10T11:55:00Z"
      ),
    ]

    let selected = SessionWorkerRosterPlanner.preferredSelectedWorkerID(
      currentSelectionID: "worker-complete-5",
      subagents: workers
    )

    #expect(selected == "worker-running")
  }

  private func makeWorker(
    id: String,
    label: String?,
    status: ServerSubagentStatus?,
    taskSummary: String?,
    resultSummary: String?,
    errorSummary: String? = nil,
    lastActivityAt: String? = nil,
    agentType: String = "agent",
    parentSubagentId: String? = nil
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
      parentSubagentId: parentSubagentId,
      model: nil,
      lastActivityAt: lastActivityAt
    )
  }

  private func makeAgentThread(
    id: String,
    label: String?,
    status: String,
    taskSummary: String?,
    resultSummary: String?,
    freshness: String,
    acceptsUserInput: Bool,
    interjectionMode: String,
    lastActivityAt: String?
  ) -> ServerAgentThreadSummary {
    let labelJSON = jsonString(label)
    let taskSummaryJSON = jsonString(taskSummary)
    let resultSummaryJSON = jsonString(resultSummary)
    let lastActivityAtJSON = jsonString(lastActivityAt)
    let json = """
    {
      "id": "\(id)",
      "provider": "codex",
      "agent_type": "general-purpose",
      "label": \(labelJSON),
      "status": "\(status)",
      "task_summary": \(taskSummaryJSON),
      "result_summary": \(resultSummaryJSON),
      "error_summary": null,
      "parent_thread_id": null,
      "model": "gpt-5.4",
      "started_at": "2026-03-10T09:00:00Z",
      "last_activity_at": \(lastActivityAtJSON),
      "ended_at": null,
      "capabilities": {
        "can_view_transcript": true,
        "has_live_updates": false,
        "accepts_user_input": \(acceptsUserInput),
        "can_interrupt": false,
        "can_resume": false,
        "can_close": false,
        "interjection_mode": "\(interjectionMode)"
      },
      "conversation": {
        "freshness": "\(freshness)",
        "has_transcript": true,
        "total_row_count": 2,
        "oldest_sequence": 1,
        "newest_sequence": 2
      },
      "limitations": []
    }
    """
    return try! JSONDecoder().decode(ServerAgentThreadSummary.self, from: Data(json.utf8))
  }

  private func jsonString(_ value: String?) -> String {
    guard let value else { return "null" }
    let data = try! JSONEncoder().encode(value)
    return String(data: data, encoding: .utf8)!
  }

  private enum RowEntryType {
    case user
    case assistant
    case thinking
  }

  private func makeRowEntry(
    id: String,
    sessionId: String,
    sequence: UInt64,
    rowType: RowEntryType,
    content: String
  ) -> ServerConversationRowEntry {
    let messageRow = ServerConversationMessageRow(
      id: id,
      content: content,
      turnId: nil,
      timestamp: nil,
      isStreaming: false,
      images: nil,
      memoryCitation: nil
    )

    let row: ServerConversationRow = switch rowType {
      case .user: .user(messageRow)
      case .assistant: .assistant(messageRow)
      case .thinking: .thinking(messageRow)
    }

    return ServerConversationRowEntry(
      sessionId: sessionId,
      sequence: sequence,
      turnId: nil,
      turnStatus: .active,
      row: row
    )
  }

  private func makeToolEntry(
    id: String,
    sessionId: String,
    sequence: UInt64,
    status: ServerConversationToolStatus,
    title: String,
    summary: String,
    startedAt: String?,
    inputDisplay: String?,
    outputDisplay: String?
  ) -> ServerConversationRowEntry {
    ServerConversationRowEntry(
      sessionId: sessionId,
      sequence: sequence,
      turnId: nil,
      turnStatus: .active,
      row: .tool(makeToolRow(
        id: id,
        sessionId: sessionId,
        sequence: sequence,
        status: status,
        title: title,
        summary: summary,
        startedAt: startedAt,
        inputDisplay: inputDisplay,
        outputDisplay: outputDisplay
      ))
    )
  }

  private func makeToolRow(
    id: String,
    sessionId: String,
    sequence: UInt64,
    status: ServerConversationToolStatus,
    title: String,
    summary: String,
    startedAt: String?,
    inputDisplay: String?,
    outputDisplay: String?
  ) -> ServerConversationToolRow {
    _ = sessionId
    _ = sequence

    return ServerConversationToolRow(
      id: id,
      provider: .codex,
      family: .agent,
      kind: .taskOutput,
      status: status,
      title: title,
      subtitle: nil,
      summary: summary,
      preview: nil,
      startedAt: startedAt,
      endedAt: nil,
      durationMs: nil,
      groupingKey: nil,
      renderHints: .init(),
      toolDisplay: ServerToolDisplay(
        summary: summary,
        subtitle: nil,
        rightMeta: nil,
        subtitleAbsorbsMeta: false,
        glyphSymbol: "person.2",
        glyphColor: "indigo",
        language: nil,
        diffPreview: nil,
        outputPreview: outputDisplay,
        liveOutputPreview: nil,
        todoItems: [],
        toolType: title,
        summaryFont: "system",
        displayTier: "standard",
        inputDisplay: inputDisplay,
        outputDisplay: outputDisplay,
        diffDisplay: nil,
        planExplanation: nil
      )
    )
  }

  private func makeWorkerEntry(
    id: String,
    sessionId: String,
    sequence: UInt64,
    workerId: String,
    title: String,
    operation: String?,
    status: ServerConversationToolStatus,
    taskSummary: String?
  ) -> ServerConversationRowEntry {
    ServerConversationRowEntry(
      sessionId: sessionId,
      sequence: sequence,
      turnId: nil,
      turnStatus: .active,
      row: .worker(ServerConversationWorkerRow(
        id: id,
        title: title,
        subtitle: nil,
        summary: nil,
        worker: ServerWorkerStateSnapshot(
          id: workerId,
          label: nil,
          agentType: "worker",
          provider: .codex,
          model: nil,
          status: status,
          taskSummary: taskSummary,
          resultSummary: nil,
          errorSummary: nil,
          parentWorkerId: nil,
          startedAt: "2026-03-10T11:00:00Z",
          lastActivityAt: "2026-03-10T11:00:00Z",
          endedAt: nil
        ),
        operation: operation,
        renderHints: .init()
      ))
    )
  }

  private func makeShellCommandEntry(
    id: String,
    sessionId: String,
    sequence: UInt64,
    title: String,
    command: String,
    stdout: String?,
    stderr: String?,
    outputPreview: String?
  ) -> ServerConversationRowEntry {
    ServerConversationRowEntry(
      sessionId: sessionId,
      sequence: sequence,
      turnId: nil,
      turnStatus: .active,
      row: .shellCommand(ServerConversationShellCommandRow(
        id: id,
        kind: .userShellCommand,
        title: title,
        summary: nil,
        command: command,
        args: [],
        stdout: stdout,
        stderr: stderr,
        outputPreview: outputPreview,
        exitCode: nil,
        durationSeconds: nil,
        cwd: nil,
        renderHints: .init()
      ))
    )
  }
}
