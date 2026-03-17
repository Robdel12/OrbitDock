import Foundation
@testable import OrbitDock
import Testing

@Suite("ConversationDetailRuntime – metadata hydration")
@MainActor
struct ConversationDetailRuntimeMetadataTests {
  @Test func hydratedApprovalStateCarriesQuestionAndPermissionDetail() throws {
    let session = ScopedSessionID(endpointId: UUID(), sessionId: "session-approval")
    let clients = try ServerClients(
      serverURL: #require(URL(string: "http://127.0.0.1:4000")),
      authToken: nil,
      dataLoader: { _ in throw HTTPTransportError.serverUnreachable }
    )
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
    #expect(approval?.id == "approval-1")
    #expect(approval?.version == 7)
    #expect(approval?.pendingQuestion == "Allow write access?")
    #expect(approval?.pendingToolName == "Bash")
    #expect(approval?.currentPrompt == "Need permission to patch a file.")
  }

  @Test func selectingWorkerPreservesInspectorStateFromWorkerPayloads() throws {
    let session = ScopedSessionID(endpointId: UUID(), sessionId: "session-worker")
    let clients = try ServerClients(
      serverURL: #require(URL(string: "http://127.0.0.1:4000")),
      authToken: nil,
      dataLoader: { _ in throw HTTPTransportError.serverUnreachable }
    )
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
            ServerSubagentTool(
              id: "tool-b",
              toolName: "Read",
              summary: "Read auth store",
              output: nil,
              isInProgress: false
            ),
          ],
        ],
        messagesByWorker: [
          "worker-b": [
            ServerConversationRowEntry(
              sessionId: session.sessionId,
              sequence: 4,
              turnId: nil,
              row: .assistant(
                ServerConversationMessageRow(
                  id: "worker-msg",
                  content: "Auth state is stable.",
                  turnId: nil,
                  timestamp: "2026-03-12T11:31:00Z",
                  isStreaming: false,
                  images: nil
                )
              )
            ),
          ],
        ],
        provider: .codex,
        model: "gpt-5.4"
      )
    )

    let metadata = runtime.renderStore.metadata
    #expect(metadata.selectedWorkerID == "worker-b")
    #expect(metadata.workerInspector.selectedWorker?.title == "Babbage")
    #expect(metadata.workerInspector.tools.first?.toolName == "Read")
    #expect(metadata.workerInspector.threadEntries.first?.body == "Auth state is stable.")
  }
}
