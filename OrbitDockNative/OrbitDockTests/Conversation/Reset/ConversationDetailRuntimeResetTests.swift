import Foundation
@testable import OrbitDock
import Testing

@Suite("ConversationDetailRuntime – reset coordination")
@MainActor
struct ConversationDetailRuntimeResetTests {
  @Test func runtimeKeepsStructureMetadataAndStreamingSeparated() throws {
    let session = ScopedSessionID(endpointId: UUID(), sessionId: "session-1")
    let clients = try ServerClients(
      serverURL: #require(URL(string: "http://127.0.0.1:4000")),
      authToken: nil,
      dataLoader: { _ in throw HTTPTransportError.serverUnreachable }
    )
    let runtime = ConversationDetailRuntime(session: session, clients: clients, provider: .codex, model: "gpt-5.4")

    runtime.applyStructure(.bootstrap(
      rows: [
        ConversationRowRecord(
          id: "message-1",
          session: session,
          kind: .message,
          payload: .message(.init(
            messageID: "message-1",
            role: .assistant,
            speaker: "Assistant",
            text: "",
            timestamp: nil,
            contentSignature: 1
          )),
          sequence: 1
        ),
      ],
      oldestLoadedSequence: 1,
      newestLoadedSequence: 1,
      hasMoreHistoryBefore: false
    ))
    runtime.hydrateMetadata(
      ConversationMetadataInput(
        isSessionActive: true,
        workStatus: .working,
        currentTool: "bash",
        approvalVersion: 3,
        workers: [],
        provider: .codex,
        model: "gpt-5.4"
      )
    )
    runtime.applyStreaming(.begin(messageID: "message-1", content: "Hello"))

    #expect(runtime.renderStore.rows.map(\.id) == ["message-1"])
    #expect(runtime.renderStore.metadata.workStatus == .working)
    #expect(runtime.renderStore.metadata.currentTool == "bash")
    #expect(runtime.renderStore.streamingMessages["message-1"]?.content == "Hello")
  }

  @Test func runtimeBuildsWorkerInspectorWithoutTranscriptScanning() throws {
    let session = ScopedSessionID(endpointId: UUID(), sessionId: "session-2")
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
        currentTool: "bash",
        approvalVersion: 2,
        workers: [
          ServerSubagentInfo(
            id: "worker-1",
            agentType: "worker",
            startedAt: "2026-03-12T12:00:00Z",
            endedAt: nil,
            provider: .codex,
            label: "Descartes",
            status: .running,
            taskSummary: "Map the auth flow",
            resultSummary: nil,
            errorSummary: nil,
            parentSubagentId: nil,
            model: "gpt-5.4",
            lastActivityAt: "2026-03-12T12:10:00Z"
          ),
          ServerSubagentInfo(
            id: "worker-2",
            agentType: "worker",
            startedAt: "2026-03-12T11:00:00Z",
            endedAt: "2026-03-12T11:30:00Z",
            provider: .codex,
            label: "Gauss",
            status: .completed,
            taskSummary: "Check tests",
            resultSummary: "Wrapped the smoke test",
            errorSummary: nil,
            parentSubagentId: "worker-1",
            model: "gpt-5.4",
            lastActivityAt: "2026-03-12T11:30:00Z"
          ),
        ],
        selectedWorkerID: "worker-1",
        toolsByWorker: [
          "worker-1": [
            ServerSubagentTool(
              id: "tool-1",
              toolName: "Read",
              summary: "Read auth files",
              output: nil,
              isInProgress: true
            ),
          ],
        ],
        messagesByWorker: [
          "worker-1": [
            ServerConversationRowEntry(
              sessionId: session.sessionId,
              sequence: 1,
              turnId: nil,
              row: .assistant(
                ServerConversationMessageRow(
                  id: "msg-1",
                  content: "I found the auth entrypoint.",
                  turnId: nil,
                  timestamp: "2026-03-12T12:11:00Z",
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
    #expect(metadata.workerCount == 2)
    #expect(metadata.activeWorkerIDs == ["worker-1"])
    #expect(metadata.selectedWorkerID == "worker-1")
    #expect(metadata.workerInspector.selectedWorker?.title == "Descartes")
    #expect(metadata.workerInspector.tools.map(\.toolName) == ["Read"])
    #expect(metadata.workerInspector.threadEntries.map(\.body) == ["I found the auth entrypoint."])
    #expect(metadata.workerInspector.childWorkerIDs == ["worker-2"])
  }
}
