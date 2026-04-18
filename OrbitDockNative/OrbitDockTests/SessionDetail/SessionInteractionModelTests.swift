import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct SessionInteractionModelTests {
  @Test func refreshPropagatesAuthoritativeDetailSnapshotToOwner() async throws {
    let fixture = ControlDeckDetailFixture()
    let runtime = try makeRuntime(loader: { request in try await fixture.loader(request) })
    let session = runtime.session("session-1")
    let model = SessionInteractionModel()
    var propagatedRevisions: [UInt64] = []

    model.bind(
      sessionId: "session-1",
      session: session,
      detailSnapshotSink: { payload in
        propagatedRevisions.append(payload.revision)
        model.applyOwnerDetailSnapshot(payload)
      }
    )

    await model.refresh()

    #expect(await fixture.detailRequestCount == 1)
    #expect(model.snapshot?.revision == 7)
    #expect(model.presentation?.mode == .compose)
    #expect(propagatedRevisions == [7])
  }

  @Test func externalDetailSnapshotAppliesLocallyWithoutEchoingBackToOwner() async throws {
    let runtime = try makeRuntime(loader: { _ in
      throw URLError(.badURL)
    })
    let session = runtime.session("session-1")
    let model = SessionInteractionModel()
    var propagatedRevisions: [UInt64] = []

    model.bind(
      sessionId: "session-1",
      session: session,
      detailSnapshotSink: { payload in
        propagatedRevisions.append(payload.revision)
      }
    )

    await model.applyExternalDetailSnapshot(Self.makePayload(revision: 11))

    #expect(model.snapshot?.revision == 11)
    #expect(model.presentation?.mode == .compose)
    #expect(propagatedRevisions.isEmpty)
  }

  @Test func staleDetailSnapshotDoesNotOverwriteNewerAppliedState() async throws {
    let model = SessionInteractionModel()
    let runtime = try makeRuntime(loader: { _ in
      throw URLError(.badURL)
    })
    let session = runtime.session("session-1")
    model.bind(sessionId: "session-1", session: session)

    await model.applyExternalDetailSnapshot(
      Self.makePayload(
        revision: 12,
        workStatus: "working",
        acceptsUserInput: true,
        steerable: true
      )
    )
    await model.applyExternalDetailSnapshot(Self.makePayload(revision: 11))

    #expect(model.snapshot?.revision == 12)
    #expect(model.presentation?.activityStatus == .working)
    #expect(model.presentation?.mode == .steer)
  }

  @Test func workingSnapshotMapsToWorkingActivityAndSteerMode() async throws {
    let model = SessionInteractionModel()
    let runtime = try makeRuntime(loader: { _ in
      throw URLError(.badURL)
    })
    let session = runtime.session("session-1")
    model.bind(sessionId: "session-1", session: session)

    await model.applyExternalDetailSnapshot(
      Self.makePayload(
        revision: 21,
        workStatus: "working",
        acceptsUserInput: true,
        steerable: true
      )
    )

    #expect(model.presentation?.activityStatus == .working)
    #expect(model.presentation?.mode == .steer)
    #expect(model.presentation?.headerSubtitle == "Working")
  }

  @Test func permissionApprovalWinsOverGenericWorkStatus() async throws {
    let model = SessionInteractionModel()
    let runtime = try makeRuntime(loader: { _ in
      throw URLError(.badURL)
    })
    let session = runtime.session("session-1")
    model.bind(sessionId: "session-1", session: session)

    await model.applyExternalDetailSnapshot(
      Self.makePayload(
        revision: 22,
        workStatus: "waiting",
        acceptsUserInput: false,
        steerable: false,
        pendingApprovalJSON: """
        {
          "id": "req-1",
          "session_id": "session-1",
          "type": "permissions",
          "requested_permissions": []
        }
        """
      )
    )

    #expect(model.presentation?.activityStatus == .permission)
    #expect(model.presentation?.mode == .approval)
    #expect(model.presentation?.headerSubtitle == "Awaiting approval")
  }

  @Test func questionApprovalMapsToQuestionActivity() async throws {
    let model = SessionInteractionModel()
    let runtime = try makeRuntime(loader: { _ in
      throw URLError(.badURL)
    })
    let session = runtime.session("session-1")
    model.bind(sessionId: "session-1", session: session)

    await model.applyExternalDetailSnapshot(
      Self.makePayload(
        revision: 23,
        workStatus: "waiting",
        acceptsUserInput: false,
        steerable: false,
        pendingApprovalJSON: """
        {
          "id": "req-2",
          "session_id": "session-1",
          "type": "question",
          "question_prompts": []
        }
        """
      )
    )

    #expect(model.presentation?.activityStatus == .question)
    #expect(model.presentation?.mode == .approval)
    #expect(model.presentation?.headerSubtitle == "Awaiting answer")
  }

  @Test func bindingNewSessionClearsPreviouslyAppliedSnapshotState() async {
    let model = SessionInteractionModel()
    let runtime = ServerEndpointRuntime.preview()
    let firstSession = runtime.session("session-1")
    let secondSession = runtime.session("session-2")

    model.bind(sessionId: "session-1", session: firstSession)
    await model.applyExternalDetailSnapshot(Self.makePayload(revision: 31))
    #expect(model.snapshot?.revision == 31)

    model.bind(sessionId: "session-2", session: secondSession)

    #expect(model.snapshot == nil)
    #expect(model.presentation == nil)
    #expect(model.lastError == nil)
  }

  @Test func submitTurnAppliesAuthoritativeDetailSnapshotFromMutationResponse() async throws {
    let fixture = ControlDeckDetailFixture()
    let runtime = try makeRuntime(loader: { request in try await fixture.loader(request) })
    let session = runtime.session("session-1")
    let model = SessionInteractionModel()
    var propagatedRevisions: [UInt64] = []
    var acceptedRowIDs: [String] = []

    model.bind(
      sessionId: "session-1",
      session: session,
      detailSnapshotSink: { payload in
        propagatedRevisions.append(payload.revision)
        model.applyOwnerDetailSnapshot(payload)
      },
      conversationRowSink: { row in
        acceptedRowIDs.append(row.id)
      }
    )

    await model.applyExternalDetailSnapshot(Self.makePayload(revision: 7))
    try await model.submitTurn(
      draft: ControlDeckDraft(text: "Ship it"),
      uploadedImageIds: [:]
    )

    #expect(await fixture.sendMessageRequestCount == 1)
    #expect(await fixture.detailRequestCount == 0)
    #expect(model.snapshot?.revision == 8)
    #expect(model.presentation?.activityStatus == .working)
    #expect(model.presentation?.mode == .steer)
    #expect(model.presentation?.headerSubtitle == "Working")
    #expect(propagatedRevisions == [8])
    #expect(acceptedRowIDs == ["send-row-1"])
  }

  @Test func interruptAppliesAuthoritativeDetailSnapshotFromMutationResponse() async throws {
    let fixture = ControlDeckDetailFixture()
    let runtime = try makeRuntime(loader: { request in try await fixture.loader(request) })
    let session = runtime.session("session-1")
    let model = SessionInteractionModel()
    var propagatedRevisions: [UInt64] = []

    model.bind(
      sessionId: "session-1",
      session: session,
      detailSnapshotSink: { payload in
        propagatedRevisions.append(payload.revision)
        model.applyOwnerDetailSnapshot(payload)
      }
    )

    await model.applyExternalDetailSnapshot(
      Self.makePayload(
        revision: 8,
        workStatus: "working",
        acceptsUserInput: true,
        steerable: true
      )
    )

    await model.interruptSession()

    #expect(await fixture.interruptRequestCount == 1)
    #expect(model.snapshot?.revision == 9)
    #expect(model.presentation?.activityStatus == .ready)
    #expect(model.presentation?.mode == .compose)
    #expect(model.presentation?.headerSubtitle == "Ready")
    #expect(propagatedRevisions == [9])
  }

  @Test func resumeAppliesAuthoritativeDetailSnapshotFromMutationResponse() async throws {
    let fixture = ControlDeckDetailFixture()
    let runtime = try makeRuntime(loader: { request in try await fixture.loader(request) })
    let session = runtime.session("session-1")
    let model = SessionInteractionModel()
    var propagatedRevisions: [UInt64] = []

    model.bind(
      sessionId: "session-1",
      session: session,
      detailSnapshotSink: { payload in
        propagatedRevisions.append(payload.revision)
        model.applyOwnerDetailSnapshot(payload)
      }
    )

    await model.applyExternalDetailSnapshot(
      Self.makePayload(
        revision: 9,
        workStatus: "waiting",
        acceptsUserInput: false,
        steerable: false
      )
    )

    await model.resumeSession()

    #expect(await fixture.resumeRequestCount == 1)
    #expect(await fixture.detailRequestCount == 0)
    #expect(model.snapshot?.revision == 10)
    #expect(model.presentation?.activityStatus == .ready)
    #expect(model.presentation?.mode == .compose)
    #expect(model.presentation?.headerSubtitle == "Ready")
    #expect(propagatedRevisions == [10])
  }

  private func makeRuntime(
    loader: @escaping ServerClients.DataLoader
  ) throws -> ServerEndpointRuntime {
    let baseURL = try #require(URL(string: "http://127.0.0.1:4000"))
    let clients = ServerClients(serverURL: baseURL, authToken: nil, dataLoader: loader)
    return ServerEndpointRuntime(
      clients: clients,
      connection: NoopEndpointRuntimeConnection(),
      endpointId: UUID()
    )
  }

  private static func makePayload(
    revision: UInt64,
    workStatus: String = "waiting",
    acceptsUserInput: Bool = true,
    steerable: Bool = false,
    canInterrupt: Bool = false,
    pendingApprovalJSON: String = "null"
  ) -> ServerSessionDetailSnapshotPayload {
    let data = Data(
      detailResponseJSON(
        revision: revision,
        workStatus: workStatus,
        acceptsUserInput: acceptsUserInput,
        steerable: steerable,
        canInterrupt: canInterrupt,
        pendingApprovalJSON: pendingApprovalJSON
      ).utf8
    )
    return try! JSONDecoder().decode(ServerSessionDetailSnapshotPayload.self, from: data)
  }

  nonisolated static func detailResponseJSON(
    revision: UInt64,
    workStatus: String = "waiting",
    acceptsUserInput: Bool = true,
    steerable: Bool = false,
    canInterrupt: Bool = false,
    pendingApprovalJSON: String = "null"
  ) -> String {
    """
    {
      "revision": \(revision),
      "session": {
        "id": "session-1",
        "provider": "claude",
        "project_path": "/tmp/project",
        "project_name": "OrbitDock",
        "status": "active",
        "work_status": "\(workStatus)",
        "control_mode": "direct",
        "lifecycle_state": "open",
        "accepts_user_input": \(acceptsUserInput),
        "steerable": \(steerable),
        "can_interrupt": \(canInterrupt),
        "rows": [],
        "total_row_count": 0,
        "has_more_before": false,
        "pending_approval": \(pendingApprovalJSON),
        "token_usage": {
          "input_tokens": 0,
          "output_tokens": 0,
          "cached_tokens": 0,
          "context_window": 0
        },
        "token_usage_snapshot_kind": "unknown",
        "allow_bypass_permissions": false,
        "turn_count": 2,
        "turn_diffs": [],
        "subagents": [],
        "is_worktree": false,
        "unread_count": 0,
        "claude_integration_mode": "direct",
        "revision": \(revision)
      }
    }
    """
  }

  nonisolated static func summaryResponseJSON(
    workStatus: String = "waiting",
    acceptsUserInput: Bool = true,
    steerable: Bool = false
  ) -> String {
    """
    {
      "id": "session-1",
      "provider": "claude",
      "project_path": "/tmp/project",
      "project_name": "OrbitDock",
      "status": "active",
      "work_status": "\(workStatus)",
      "control_mode": "direct",
      "lifecycle_state": "open",
      "accepts_user_input": \(acceptsUserInput),
      "steerable": \(steerable),
      "token_usage": {
        "input_tokens": 0,
        "output_tokens": 0,
        "cached_tokens": 0,
        "context_window": 0
      },
      "token_usage_snapshot_kind": "unknown",
      "has_pending_approval": false,
      "allow_bypass_permissions": false,
      "is_worktree": false,
      "unread_count": 0,
      "display_title": "OrbitDock",
      "list_status": "reply",
      "summary_revision": 1
    }
    """
  }
}

@MainActor
private final class NoopEndpointRuntimeConnection: ServerEndpointRuntimeConnection {
  let connectionStatus: ConnectionStatus = .connected
  let isRemote: Bool = false

  func addListener(_ listener: @escaping (ServerEvent) -> Void) -> ServerConnectionListenerToken {
    unsafeBitCast(UUID(), to: ServerConnectionListenerToken.self)
  }

  func removeListener(_ token: ServerConnectionListenerToken) {}
  func subscribeMissions(sinceRevision: UInt64?) {}
  func unsubscribeMissions() {}
  func subscribeMission(_ missionId: String) {}
  func unsubscribeMission(_ missionId: String) {}
  func resubscribeMission(_ missionId: String) {}
  func subscribeSessionSurface(_ sessionId: String, surface: ServerSessionSurface, sinceRevision: UInt64?) {}
  func unsubscribeSessionSurface(_ sessionId: String, surface: ServerSessionSurface) {}
  func failConnection(message: String) {}
}

private actor ControlDeckDetailFixture {
  private(set) var detailRequestCount = 0
  private(set) var sendMessageRequestCount = 0
  private(set) var interruptRequestCount = 0
  private(set) var resumeRequestCount = 0

  func loader(_ request: URLRequest) async throws -> (Data, URLResponse) {
    guard let url = request.url else {
      throw URLError(.badURL)
    }

    let response = HTTPURLResponse(
      url: url,
      statusCode: 200,
      httpVersion: nil,
      headerFields: [
        "Content-Type": "application/json",
        "X-OrbitDock-Server-Version": "0.9.0",
        "X-OrbitDock-Minimum-Client-Version": "0.4.0",
      ]
    )!

    switch (request.httpMethod ?? "GET", url.path) {
      case ("GET", "/api/sessions/session-1/detail"):
        detailRequestCount += 1
        return (
          Data(SessionInteractionModelTests.detailResponseJSON(revision: 7).utf8),
          response
        )
      case ("POST", "/api/sessions/session-1/conversation/messages"):
        sendMessageRequestCount += 1
        return (
          Data(
            """
            {
              "accepted": true,
              "row": {
                "session_id": "session-1",
                "sequence": 1,
                "turn_id": "turn-1",
                "row": {
                  "row_type": "user",
                  "id": "send-row-1",
                  "content": "Ship it",
                  "is_streaming": false
                }
              },
              "session_detail_snapshot": \(SessionInteractionModelTests.detailResponseJSON(
                revision: 8,
                workStatus: "working",
                acceptsUserInput: true,
                steerable: true,
                canInterrupt: true
              ))
            }
            """.utf8
          ),
          response
        )
      case ("POST", "/api/sessions/session-1/conversation/interrupt"):
        interruptRequestCount += 1
        return (
          Data(
            """
            {
              "accepted": true,
              "session_detail_snapshot": \(SessionInteractionModelTests.detailResponseJSON(
                revision: 9,
                workStatus: "waiting",
                acceptsUserInput: true,
                steerable: false
              ))
            }
            """.utf8
          ),
          response
        )
      case ("POST", "/api/sessions/session-1/lifecycle/resume"):
        resumeRequestCount += 1
        return (
          Data(
            """
            {
              "session_id": "session-1",
              "session": \(SessionInteractionModelTests.summaryResponseJSON()),
              "session_detail_snapshot": \(SessionInteractionModelTests.detailResponseJSON(
                revision: 10,
                workStatus: "waiting",
                acceptsUserInput: true,
                steerable: false
              ))
            }
            """.utf8
          ),
          response
        )
      default:
        throw URLError(.badURL)
    }
  }
}
