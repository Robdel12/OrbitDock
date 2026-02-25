import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct UnifiedSessionsStoreTests {
  @Test func sessionRefRoundTripsScopedID() throws {
    let ref = try SessionRef(
      endpointId: #require(UUID(uuidString: "f0f0f0f0-f0f0-f0f0-f0f0-f0f0f0f0f0f0")),
      sessionId: "sess-123"
    )

    let parsed = SessionRef(scopedID: ref.scopedID)

    #expect(parsed == ref)
  }

  @Test func projectionMergesEndpointSessionsWithScopedRefs() throws {
    let endpointA = try ServerEndpoint(
      id: #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111")),
      name: "Alpha",
      wsURL: #require(URL(string: "ws://127.0.0.1:4000/ws")),
      isLocalManaged: true,
      isEnabled: true,
      isDefault: true
    )
    let endpointB = try ServerEndpoint(
      id: #require(UUID(uuidString: "22222222-2222-2222-2222-222222222222")),
      name: "Beta",
      wsURL: #require(URL(string: "ws://10.0.0.2:4100/ws")),
      isLocalManaged: false,
      isEnabled: true,
      isDefault: false
    )

    let sessionA = makeSession(
      id: "shared-session-id",
      projectPath: "/Users/alice/ProjectA",
      status: .active,
      workStatus: .working,
      lastActivityAt: Date(timeIntervalSince1970: 200)
    )
    let sessionB = makeSession(
      id: "shared-session-id",
      projectPath: "/Users/alice/ProjectB",
      status: .active,
      workStatus: .waiting,
      attentionReason: .awaitingReply,
      lastActivityAt: Date(timeIntervalSince1970: 100)
    )

    let snapshot = UnifiedSessionsProjection.snapshot(
      from: [
        .init(endpoint: endpointA, status: .connected, sessions: [sessionA]),
        .init(endpoint: endpointB, status: .connected, sessions: [sessionB]),
      ],
      filter: .all
    )

    #expect(snapshot.sessions.count == 2)
    #expect(snapshot.sessionRefsByScopedID.count == 2)

    let scopedIDs = Set(snapshot.sessions.map(\.scopedID))
    #expect(scopedIDs.count == 2)
    #expect(snapshot.sessions.allSatisfy { $0.endpointId != nil })
    #expect(snapshot.sessions.map(\.endpointName).compactMap { $0 }.sorted() == ["Alpha", "Beta"])
    #expect(snapshot.counts.total == 2)
    #expect(snapshot.counts.active == 2)
    #expect(snapshot.counts.working == 1)
    #expect(snapshot.counts.ready == 1)
  }

  @Test func projectionFiltersByEndpoint() throws {
    let endpointA = try ServerEndpoint(
      id: #require(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")),
      name: "Alpha",
      wsURL: #require(URL(string: "ws://127.0.0.1:4000/ws")),
      isLocalManaged: true,
      isEnabled: true,
      isDefault: true
    )
    let endpointB = try ServerEndpoint(
      id: #require(UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")),
      name: "Beta",
      wsURL: #require(URL(string: "ws://10.0.0.2:4100/ws")),
      isLocalManaged: false,
      isEnabled: true,
      isDefault: false
    )

    let snapshot = UnifiedSessionsProjection.snapshot(
      from: [
        .init(endpoint: endpointA, status: .connected, sessions: [makeSession(id: "a-1", projectPath: "/A")]),
        .init(endpoint: endpointB, status: .connected, sessions: [makeSession(id: "b-1", projectPath: "/B")]),
      ],
      filter: .endpoint(endpointA.id)
    )

    #expect(snapshot.sessions.count == 1)
    #expect(snapshot.sessions.first?.endpointId == endpointA.id)
    #expect(snapshot.sessions.first?.id == "a-1")
  }

  @Test func projectionSortsActiveBeforeEndedThenByActivity() throws {
    let endpoint = try ServerEndpoint(
      id: #require(UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")),
      name: "Solo",
      wsURL: #require(URL(string: "ws://127.0.0.1:4000/ws")),
      isLocalManaged: true,
      isEnabled: true,
      isDefault: true
    )

    let oldestActive = makeSession(
      id: "old-active",
      projectPath: "/repo/old-active",
      status: .active,
      workStatus: .waiting,
      lastActivityAt: Date(timeIntervalSince1970: 100)
    )
    let newestActive = makeSession(
      id: "new-active",
      projectPath: "/repo/new-active",
      status: .active,
      workStatus: .working,
      lastActivityAt: Date(timeIntervalSince1970: 300)
    )
    let endedRecent = makeSession(
      id: "ended-recent",
      projectPath: "/repo/ended",
      status: .ended,
      workStatus: .unknown,
      lastActivityAt: Date(timeIntervalSince1970: 400)
    )

    let snapshot = UnifiedSessionsProjection.snapshot(
      from: [
        .init(endpoint: endpoint, status: .connected, sessions: [oldestActive, newestActive, endedRecent]),
      ],
      filter: .all
    )

    #expect(snapshot.sessions.map(\.id) == ["new-active", "old-active", "ended-recent"])
  }

  @Test func projectionSortsEndpointHealthDeterministically() throws {
    let endpointZulu = try ServerEndpoint(
      id: #require(UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")),
      name: "Zulu",
      wsURL: #require(URL(string: "ws://127.0.0.1:4001/ws")),
      isLocalManaged: true,
      isEnabled: true,
      isDefault: false
    )
    let endpointAlpha = try ServerEndpoint(
      id: #require(UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")),
      name: "Alpha",
      wsURL: #require(URL(string: "ws://127.0.0.1:4000/ws")),
      isLocalManaged: true,
      isEnabled: true,
      isDefault: true
    )

    let snapshot = UnifiedSessionsProjection.snapshot(
      from: [
        .init(endpoint: endpointZulu, status: .disconnected, sessions: [makeSession(id: "z-1", projectPath: "/z")]),
        .init(endpoint: endpointAlpha, status: .connected, sessions: [makeSession(id: "a-1", projectPath: "/a")]),
      ],
      filter: .all
    )

    #expect(snapshot.endpointHealth.map(\.endpointName) == ["Alpha", "Zulu"])
    #expect(snapshot.endpointHealth.first?.status == .connected)
    #expect(snapshot.endpointHealth.last?.status == .disconnected)
  }
}

private func makeSession(
  id: String,
  projectPath: String,
  status: Session.SessionStatus = .active,
  workStatus: Session.WorkStatus = .waiting,
  attentionReason: Session.AttentionReason = .none,
  lastActivityAt: Date? = nil
) -> Session {
  Session(
    id: id,
    projectPath: projectPath,
    projectName: URL(fileURLWithPath: projectPath).lastPathComponent,
    status: status,
    workStatus: workStatus,
    startedAt: Date(timeIntervalSince1970: 0),
    lastActivityAt: lastActivityAt,
    attentionReason: attentionReason
  )
}
