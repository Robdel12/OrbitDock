@testable import OrbitDock
import XCTest

final class ConversationMetadataStoreTests: XCTestCase {
  func testHydrateBuildsWorkerApprovalAndInspectorStateTogether() {
    let session = ScopedSessionID(endpointId: UUID(), sessionId: "session-1")
    var store = ConversationMetadataStore(session: session, provider: .codex, model: "gpt-5.4")

    store.apply(.hydrate(
      ConversationMetadataInput(
        isSessionActive: true,
        workStatus: .working,
        currentTool: "bash",
        approval: ServerApprovalRequest(
          id: "approval-1",
          sessionId: session.sessionId,
          type: .question,
          toolName: "Bash",
          question: "Ship it?"
        ),
        approvalVersion: 7,
        workers: [
          ServerSubagentInfo(
            id: "worker-1",
            agentType: "worker",
            startedAt: "2026-03-12T12:00:00Z",
            endedAt: nil,
            provider: .codex,
            label: "Descartes",
            status: .pending,
            taskSummary: "Inspect auth",
            resultSummary: nil,
            errorSummary: nil,
            parentSubagentId: nil,
            model: nil,
            lastActivityAt: "2026-03-12T12:01:00Z"
          ),
          ServerSubagentInfo(
            id: "worker-2",
            agentType: "worker",
            startedAt: "2026-03-12T12:00:00Z",
            endedAt: nil,
            provider: .codex,
            label: "Gauss",
            status: .completed,
            taskSummary: nil,
            resultSummary: "Wrapped the smoke test",
            errorSummary: nil,
            parentSubagentId: "worker-1",
            model: nil,
            lastActivityAt: "2026-03-12T12:03:00Z"
          ),
        ],
        selectedWorkerID: "worker-1",
        toolsByWorker: [
          "worker-1": [
            ServerSubagentTool(id: "tool-1", toolName: "Read", summary: "Read auth", output: nil, isInProgress: true),
          ],
        ],
        messagesByWorker: [
          "worker-1": [
            makeRowEntry(
              id: "msg-1",
              sessionId: session.sessionId,
              sequence: 1,
              content: "I found the auth entrypoint."
            ),
          ],
        ],
        provider: .codex,
        model: "gpt-5.4"
      )
    ))

    XCTAssertEqual(store.snapshot.workerIDs, ["worker-1", "worker-2"])
    XCTAssertEqual(store.snapshot.activeWorkerIDs, ["worker-1"])
    XCTAssertEqual(store.snapshot.approvalID, "approval-1")
    XCTAssertEqual(store.snapshot.approvalVersion, 7)
    XCTAssertEqual(store.snapshot.pendingQuestion, "Ship it?")
    XCTAssertEqual(store.snapshot.workStatus, .working)
    XCTAssertEqual(store.snapshot.currentTool, "bash")
    XCTAssertEqual(store.snapshot.provider, .codex)
    XCTAssertEqual(store.snapshot.model, "gpt-5.4")
    XCTAssertEqual(store.snapshot.workerInspector.selectedWorker?.title, "Descartes")
    XCTAssertEqual(store.snapshot.workerInspector.tools.first?.toolName, "Read")
    XCTAssertEqual(store.snapshot.workerInspector.threadEntries.first?.body, "I found the auth entrypoint.")
  }

  func testSelectingWorkerUsesStoredInspectorPayloadWithoutRehydratingTranscript() {
    let session = ScopedSessionID(endpointId: UUID(), sessionId: "session-2")
    var store = ConversationMetadataStore(session: session)

    store.apply(.hydrate(
      ConversationMetadataInput(
        isSessionActive: true,
        workStatus: .working,
        workers: [
          ServerSubagentInfo(
            id: "worker-1",
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
            lastActivityAt: "2026-03-12T12:01:00Z"
          ),
          ServerSubagentInfo(
            id: "worker-2",
            agentType: "worker",
            startedAt: "2026-03-12T12:00:00Z",
            endedAt: nil,
            provider: .codex,
            label: "Grace",
            status: .completed,
            taskSummary: nil,
            resultSummary: "Auth state looks good.",
            errorSummary: nil,
            parentSubagentId: nil,
            model: nil,
            lastActivityAt: "2026-03-12T12:02:00Z"
          ),
        ],
        selectedWorkerID: "worker-1",
        toolsByWorker: [
          "worker-2": [
            ServerSubagentTool(
              id: "tool-2",
              toolName: "Search",
              summary: "Search auth state",
              output: nil,
              isInProgress: false
            ),
          ],
        ],
        messagesByWorker: [
          "worker-2": [
            makeRowEntry(
              id: "msg-2",
              sessionId: session.sessionId,
              sequence: 2,
              content: "Auth state looks good."
            ),
          ],
        ],
        provider: .codex
      )
    ))

    store.apply(.selectWorker("worker-2"))

    XCTAssertEqual(store.snapshot.selectedWorkerID, "worker-2")
    XCTAssertEqual(store.snapshot.workerInspector.selectedWorker?.title, "Grace")
    XCTAssertEqual(store.snapshot.workerInspector.tools.first?.toolName, "Search")
    XCTAssertEqual(store.snapshot.workerInspector.threadEntries.first?.body, "Auth state looks good.")
  }

  private func makeRowEntry(
    id: String,
    sessionId: String,
    sequence: UInt64,
    content: String
  ) -> ServerConversationRowEntry {
    ServerConversationRowEntry(
      sessionId: sessionId,
      sequence: sequence,
      turnId: nil,
      row: .assistant(
        ServerConversationMessageRow(
          id: id,
          content: content,
          turnId: nil,
          timestamp: nil,
          isStreaming: false,
          images: nil
        )
      )
    )
  }
}
