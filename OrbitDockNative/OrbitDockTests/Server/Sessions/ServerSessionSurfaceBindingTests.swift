import Foundation
@testable import OrbitDock
import Testing

@Suite(.serialized)
@MainActor
struct ServerSessionSurfaceBindingTests {
  @Test func conversationRefreshIgnoresStalePayloadAfterSessionRebind() async throws {
    let fixture = ConversationSurfaceSwitchFixture()
    let runtime = try makeRuntime(loader: { request in try await fixture.loader(request) })
    let firstSession = runtime.session("session-1")
    let secondSession = runtime.session("session-2")
    let viewModel = ConversationViewModel(
      sessionId: "session-1",
      session: firstSession,
      viewMode: .focused
    )

    let firstRefresh = Task { await viewModel.refresh() }
    await fixture.waitForFirstSessionConversationRequest()

    viewModel.bind(sessionId: "session-2", session: secondSession, viewMode: .focused)
    await viewModel.refresh()
    await fixture.waitForSecondSessionConversationRequest()
    await fixture.releaseFirstSessionConversationRequest()
    await firstRefresh.value

    #expect(viewModel.currentSessionId == "session-2")
    #expect(viewModel.loadState == .ready)
    #expect(viewModel.hasTimeline)
    #expect(viewModel.timelineViewModel.displayedEntryCount == 1)
  }

  @Test func reviewRefreshIgnoresStaleDiffPayloadAfterSessionRebind() async throws {
    let fixture = ReviewSurfaceSwitchFixture()
    let runtime = try makeRuntime(loader: { request in try await fixture.loader(request) })
    let firstSession = runtime.session("session-1")
    let secondSession = runtime.session("session-2")
    let viewModel = ReviewCanvasViewModel(sessionId: "session-1", session: firstSession)

    let firstRefresh = Task { await viewModel.refresh() }
    await fixture.waitForFirstSessionDiffRequest()

    viewModel.bind(sessionId: "session-2", session: secondSession)
    await viewModel.refresh()
    await fixture.releaseFirstSessionDiffRequest()
    await firstRefresh.value

    #expect(viewModel.reviewComments.map(\.id) == ["comment-2"])
    #expect(viewModel.turnDiffs.map(\.turnId) == ["turn-2"])
    #expect(viewModel.currentDiff == "diff two")
    #expect(viewModel.cumulativeDiff == "diff two")
  }

  @Test func reviewRefreshIgnoresOlderPayloadAfterNewerStateApplied() async throws {
    let runtime = try makeRuntime(loader: { _ in
      throw URLError(.badURL)
    })
    let session = runtime.session("session-1")
    let viewModel = ReviewCanvasViewModel(sessionId: "session-1", session: session)

    viewModel.bind(sessionId: "session-1", session: session)
    viewModel.applyReviewSnapshotPayload(
      try JSONDecoder().decode(
        ServerSessionReviewSnapshotPayload.self,
        from: Data(
          Self.reviewSnapshotJSON(
            sessionId: "session-1",
            commentId: "comment-1",
            body: "newer",
            turnId: "turn-1",
            diff: "diff newer",
            revision: 12
          ).utf8
        )
      )
    )
    viewModel.applyReviewSnapshotPayload(
      try JSONDecoder().decode(
        ServerSessionReviewSnapshotPayload.self,
        from: Data(
          Self.reviewSnapshotJSON(
            sessionId: "session-1",
            commentId: "comment-1",
            body: "stale",
            turnId: "turn-1",
            diff: "diff stale",
            revision: 11
          ).utf8
        )
      )
    )

    #expect(viewModel.reviewComments.first?.body == "newer")
    #expect(viewModel.currentDiff == "diff newer")
    #expect(viewModel.cumulativeDiff == "diff newer")
  }

  @Test func sessionDetailRefreshIgnoresStalePayloadAfterSessionRebind() async throws {
    let fixture = SessionDetailSurfaceSwitchFixture()
    let runtime = try makeRuntime(loader: { request in try await fixture.loader(request) })
    let endpointId = runtime.endpointId
    let firstSession = runtime.session("session-1")
    let secondSession = runtime.session("session-2")
    let viewModel = SessionDetailViewModel(
      sessionId: "session-1",
      endpointId: endpointId,
      session: firstSession
    )

    viewModel.bind(
      sessionId: "session-1",
      endpointId: endpointId,
      session: firstSession,
      modelPricingService: ModelPricingService()
    )

    let firstRefresh = Task { await viewModel.refresh() }
    await fixture.waitForFirstSessionDetailRequest()

    viewModel.bind(
      sessionId: "session-2",
      endpointId: endpointId,
      session: secondSession,
      modelPricingService: ModelPricingService()
    )
    await viewModel.refresh()
    await fixture.releaseFirstSessionDetailRequest()
    await firstRefresh.value

    #expect(viewModel.detailPayload?.session.id == "session-2")
    #expect(viewModel.detailPayload?.revision == 22)
  }

  @Test func sessionDetailIgnoresOlderPayloadAfterNewerStateApplied() async throws {
    let runtime = try makeRuntime(loader: { _ in
      throw URLError(.badURL)
    })
    let endpointId = runtime.endpointId
    let session = runtime.session("session-1")
    let viewModel = SessionDetailViewModel(
      sessionId: "session-1",
      endpointId: endpointId,
      session: session
    )

    viewModel.bind(
      sessionId: "session-1",
      endpointId: endpointId,
      session: session,
      modelPricingService: ModelPricingService()
    )

    viewModel.applyDetailPayload(
      try JSONDecoder().decode(
        ServerSessionDetailSnapshotPayload.self,
        from: Data(Self.detailSnapshotJSON(sessionId: "session-1", revision: 12, projectName: "OrbitDock").utf8)
      )
    )
    viewModel.applyDetailPayload(
      try JSONDecoder().decode(
        ServerSessionDetailSnapshotPayload.self,
        from: Data(Self.detailSnapshotJSON(sessionId: "session-1", revision: 11, projectName: "Stale").utf8)
      )
    )

    #expect(viewModel.detailPayload?.revision == 12)
    #expect(viewModel.detailPayload?.session.projectName == "OrbitDock")
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

  fileprivate nonisolated static func makeHTTPResponse(for url: URL, json: String) -> (Data, URLResponse) {
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
    return (Data(json.utf8), response)
  }

  fileprivate nonisolated static func reviewSnapshotJSON(
    sessionId: String,
    commentId: String,
    body: String,
    turnId: String,
    diff: String,
    revision: UInt64 = 1
  ) -> String {
    #"""
    {
      "session_id": "\#(sessionId)",
      "revision": \#(revision),
      "current_diff": "\#(diff)",
      "cumulative_diff": "\#(diff)",
      "turn_diffs": [
        {
          "turn_id": "\#(turnId)",
          "diff": "\#(diff)"
        }
      ],
      "comments": [
        {
          "id": "\#(commentId)",
          "session_id": "\#(sessionId)",
          "turn_id": "turn-\#(sessionId.suffix(1))",
          "file_path": "Sources/File.swift",
          "line_start": 1,
          "line_end": 1,
          "body": "\#(body)",
          "tag": null,
          "status": "open",
          "created_at": "2026-01-01T00:00:00Z",
          "updated_at": null
        }
      ]
    }
    """#
  }

  fileprivate nonisolated static func detailSnapshotJSON(
    sessionId: String,
    revision: UInt64,
    projectName: String
  ) -> String {
    ControlDeckSessionModelTests.detailResponseJSON(revision: revision)
      .replacingOccurrences(
        of: "\"id\": \"session-1\"",
        with: "\"id\": \"\(sessionId)\""
      )
      .replacingOccurrences(
        of: "\"project_name\": \"OrbitDock\"",
        with: "\"project_name\": \"\(projectName)\""
      )
  }
}

actor ConversationSurfaceSwitchFixture {
  private var firstSessionConversationStarted = false
  private var firstSessionConversationReleased = false
  private var secondSessionConversationStarted = false
  private var firstSessionConversationStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var secondSessionConversationStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var firstSessionConversationReleaseWaiters: [CheckedContinuation<Void, Never>] = []

  func loader(_ request: URLRequest) async throws -> (Data, URLResponse) {
    let path = request.url?.path ?? ""
    guard let url = request.url else { throw URLError(.badURL) }
    guard path.hasSuffix("/conversation") else {
      throw URLError(.badURL)
    }

    if path.contains("/session-1/") {
      firstSessionConversationStarted = true
      resume(waiters: &firstSessionConversationStartWaiters)
      if !firstSessionConversationReleased {
        await withCheckedContinuation { continuation in
          firstSessionConversationReleaseWaiters.append(continuation)
        }
      }
      return ServerSessionSurfaceBindingTests.makeHTTPResponse(
        for: url,
        json: conversationBootstrapJSON(
          sessionId: "session-1",
          rowId: "row-1",
          content: "first conversation"
        )
      )
    }

    secondSessionConversationStarted = true
    resume(waiters: &secondSessionConversationStartWaiters)
    return ServerSessionSurfaceBindingTests.makeHTTPResponse(
      for: url,
      json: conversationBootstrapJSON(
        sessionId: "session-2",
        rowId: "row-2",
        content: "second conversation"
      )
    )
  }

  func waitForFirstSessionConversationRequest() async {
    guard !firstSessionConversationStarted else { return }
    await withCheckedContinuation { continuation in
      firstSessionConversationStartWaiters.append(continuation)
    }
  }

  func releaseFirstSessionConversationRequest() {
    firstSessionConversationReleased = true
    resume(waiters: &firstSessionConversationReleaseWaiters)
  }

  func waitForSecondSessionConversationRequest() async {
    guard !secondSessionConversationStarted else { return }
    await withCheckedContinuation { continuation in
      secondSessionConversationStartWaiters.append(continuation)
    }
  }

  private func conversationBootstrapJSON(
    sessionId: String,
    rowId: String,
    content: String
  ) -> String {
    #"""
    {
      "session": {
        "id": "\#(sessionId)",
        "provider": "claude",
        "project_path": "/tmp/project",
        "project_name": "OrbitDock",
        "status": "active",
        "work_status": "waiting",
        "control_mode": "direct",
        "lifecycle_state": "open",
        "accepts_user_input": true,
        "steerable": false,
        "rows": [
          {
            "session_id": "\#(sessionId)",
            "sequence": 1,
            "turn_id": "turn-1",
            "turn_status": "active",
            "row": {
              "row_type": "assistant",
              "id": "\#(rowId)",
              "content": "\#(content)",
              "is_streaming": false
            }
          }
        ],
        "total_row_count": 1,
        "has_more_before": false,
        "token_usage": {
          "input_tokens": 0,
          "output_tokens": 0,
          "cached_tokens": 0,
          "context_window": 0
        },
        "token_usage_snapshot_kind": "unknown",
        "allow_bypass_permissions": false,
        "turn_count": 1,
        "turn_diffs": [],
        "subagents": [],
        "is_worktree": false,
        "unread_count": 0,
        "claude_integration_mode": "direct",
        "revision": 1
      },
      "forked_from_session_id": null,
      "replay_cursor": 1,
      "total_row_count": 1,
      "has_more_before": false,
      "rows": [
        {
          "session_id": "\#(sessionId)",
          "sequence": 1,
          "turn_id": "turn-1",
          "turn_status": "active",
          "row": {
            "row_type": "assistant",
            "id": "\#(rowId)",
            "content": "\#(content)",
            "is_streaming": false
          }
        }
      ]
    }
    """#
  }

  private func resume(waiters: inout [CheckedContinuation<Void, Never>]) {
    for waiter in waiters {
      waiter.resume()
    }
    waiters.removeAll()
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

actor ReviewSurfaceSwitchFixture {
  private var firstSessionReviewStarted = false
  private var firstSessionReviewReleased = false
  private var firstSessionReviewStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var firstSessionReviewReleaseWaiters: [CheckedContinuation<Void, Never>] = []

  func loader(_ request: URLRequest) async throws -> (Data, URLResponse) {
    let path = request.url?.path ?? ""
    guard let url = request.url else { throw URLError(.badURL) }

    guard path.hasSuffix("/review") else {
      throw URLError(.badURL)
    }

    if path.contains("/session-1/") {
      firstSessionReviewStarted = true
      resume(waiters: &firstSessionReviewStartWaiters)
      if !firstSessionReviewReleased {
        await withCheckedContinuation { continuation in
          firstSessionReviewReleaseWaiters.append(continuation)
        }
      }
      return ServerSessionSurfaceBindingTests.makeHTTPResponse(
        for: url,
        json: ServerSessionSurfaceBindingTests.reviewSnapshotJSON(
          sessionId: "session-1",
          commentId: "comment-1",
          body: "comment one",
          turnId: "turn-1",
          diff: "diff one"
        )
      )
    }

    return ServerSessionSurfaceBindingTests.makeHTTPResponse(
      for: url,
      json: ServerSessionSurfaceBindingTests.reviewSnapshotJSON(
        sessionId: "session-2",
        commentId: "comment-2",
        body: "comment two",
        turnId: "turn-2",
        diff: "diff two"
      )
    )
  }

  func waitForFirstSessionDiffRequest() async {
    guard !firstSessionReviewStarted else { return }
    await withCheckedContinuation { continuation in
      firstSessionReviewStartWaiters.append(continuation)
    }
  }

  func releaseFirstSessionDiffRequest() {
    firstSessionReviewReleased = true
    resume(waiters: &firstSessionReviewReleaseWaiters)
  }

  private func resume(waiters: inout [CheckedContinuation<Void, Never>]) {
    for waiter in waiters {
      waiter.resume()
    }
    waiters.removeAll()
  }
}

actor SessionDetailSurfaceSwitchFixture {
  private var firstSessionDetailStarted = false
  private var firstSessionDetailReleased = false
  private var firstSessionDetailStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var firstSessionDetailReleaseWaiters: [CheckedContinuation<Void, Never>] = []

  func loader(_ request: URLRequest) async throws -> (Data, URLResponse) {
    let path = request.url?.path ?? ""
    guard let url = request.url else { throw URLError(.badURL) }
    guard path.hasSuffix("/detail") else {
      throw URLError(.badURL)
    }

    if path.contains("/session-1/") {
      firstSessionDetailStarted = true
      resume(waiters: &firstSessionDetailStartWaiters)
      if !firstSessionDetailReleased {
        await withCheckedContinuation { continuation in
          firstSessionDetailReleaseWaiters.append(continuation)
        }
      }
      return ServerSessionSurfaceBindingTests.makeHTTPResponse(
        for: url,
        json: ServerSessionSurfaceBindingTests.detailSnapshotJSON(
          sessionId: "session-1",
          revision: 11,
          projectName: "First Project"
        )
      )
    }

    return ServerSessionSurfaceBindingTests.makeHTTPResponse(
      for: url,
      json: ServerSessionSurfaceBindingTests.detailSnapshotJSON(
        sessionId: "session-2",
        revision: 22,
        projectName: "Second Project"
      )
    )
  }

  func waitForFirstSessionDetailRequest() async {
    guard !firstSessionDetailStarted else { return }
    await withCheckedContinuation { continuation in
      firstSessionDetailStartWaiters.append(continuation)
    }
  }

  func releaseFirstSessionDetailRequest() async {
    firstSessionDetailReleased = true
    resume(waiters: &firstSessionDetailReleaseWaiters)
  }

  private func resume(waiters: inout [CheckedContinuation<Void, Never>]) {
    for waiter in waiters {
      waiter.resume()
    }
    waiters.removeAll()
  }
}
