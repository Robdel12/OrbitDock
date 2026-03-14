import XCTest
@testable import OrbitDock

@MainActor
final class ConversationDetailRuntimeMetadataTests: XCTestCase {
  func testHydratedApprovalStateCarriesQuestionAndPermissionDetail() {
    let session = ScopedSessionID(endpointId: UUID(), sessionId: "session-approval")
    let clients = ServerClients(serverURL: URL(string: "http://127.0.0.1:4000")!, authToken: nil)
    let runtime = ConversationDetailRuntime(session: session, clients: clients, provider: .codex, model: "gpt-5.4")

    runtime.hydrateMetadata(
      ConversationMetadataInput(
        isSessionActive: true,
        workStatus: .permission,
        currentTool: "bash",
        pendingToolName: "Bash",
        pendingPermissionDetail: "Write access to Sources/App.swift",
        currentPrompt: "Need permission to patch a file.",
        approval: ServerApprovalRequest(
          id: "approval-1",
          sessionId: session.sessionId,
          type: .permissions,
          toolName: "Bash",
          permissionReason: "Need write access"
        ),
        approvalVersion: 7,
        pendingQuestion: "Allow write access?",
        provider: .codex,
        model: "gpt-5.4"
      )
    )

    let approval = runtime.renderStore.metadata.approval
    XCTAssertEqual(approval?.id, "approval-1")
    XCTAssertEqual(approval?.version, 7)
    XCTAssertEqual(approval?.pendingQuestion, "Allow write access?")
    XCTAssertEqual(approval?.pendingToolName, "Bash")
    XCTAssertEqual(approval?.currentPrompt, "Need permission to patch a file.")
  }

  func testSelectingWorkerPreservesInspectorStateFromWorkerPayloads() {
    let session = ScopedSessionID(endpointId: UUID(), sessionId: "session-worker")
    let clients = ServerClients(serverURL: URL(string: "http://127.0.0.1:4000")!, authToken: nil)
    let runtime = ConversationDetailRuntime(session: session, clients: clients, provider: .codex, model: "gpt-5.4")

    runtime.hydrateMetadata(
      ConversationMetadataInput(
        isSessionActive: true,
        workStatus: .working,
        workers: [
          ServerSubagentInfo(
            id: "worker-a",
            agentType: "worker",
            startedAt: "2026-03-12T12:00:00Z",
            endedAt: nil,
            provider: .codex,
            label: "Ada",
            status: .running,
            taskSummary: "Inspect auth state",
            resultSummary: nil,
            errorSummary: nil,
            parentSubagentId: nil,
            model: nil,
            lastActivityAt: "2026-03-12T12:05:00Z"
          ),
          ServerSubagentInfo(
            id: "worker-b",
            agentType: "worker",
            startedAt: "2026-03-12T11:00:00Z",
            endedAt: "2026-03-12T11:30:00Z",
            provider: .codex,
            label: "Babbage",
            status: .completed,
            taskSummary: nil,
            resultSummary: "Auth state is stable.",
            errorSummary: nil,
            parentSubagentId: nil,
            model: nil,
            lastActivityAt: "2026-03-12T11:30:00Z"
          ),
        ],
        selectedWorkerID: "worker-b",
        toolsByWorker: [
          "worker-b": [
            ServerSubagentTool(id: "tool-b", toolName: "Read", summary: "Read auth store", output: nil, isInProgress: false)
          ]
        ],
        messagesByWorker: [
          "worker-b": [
            ServerMessage(
              id: "worker-msg",
              sessionId: session.sessionId,
              sequence: 4,
              type: .assistant,
              content: "Auth state is stable.",
              toolName: nil,
              toolInput: nil,
              toolOutput: nil,
              isError: false,
              isInProgress: false,
              timestamp: "2026-03-12T11:31:00Z",
              durationMs: nil,
              images: []
            )
          ]
        ],
        provider: .codex,
        model: "gpt-5.4"
      )
    )

    let metadata = runtime.renderStore.metadata
    XCTAssertEqual(metadata.selectedWorkerID, "worker-b")
    XCTAssertEqual(metadata.workerInspector.selectedWorker?.title, "Babbage")
    XCTAssertEqual(metadata.workerInspector.tools.first?.toolName, "Read")
    XCTAssertEqual(metadata.workerInspector.threadEntries.first?.body, "Auth state is stable.")
  }
}
