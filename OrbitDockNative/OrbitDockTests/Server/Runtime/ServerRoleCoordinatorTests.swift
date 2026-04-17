import Foundation
@testable import OrbitDock
import Testing

struct ServerRoleCoordinatorTests {
  @Test func reconcileAppliesPrimaryClaimWritesInStableOrder() async throws {
    let endpointA = try #require(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))
    let endpointB = try #require(UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"))
    let recorder = ServerRoleRecorder()
    let coordinator = ServerRoleCoordinator()

    await coordinator.submitPrimaryClaimPlan(
      ServerRolePlan(
        enabledEndpointIds: [endpointA, endpointB],
        primaryEndpointId: endpointB
      ),
      ports: [
        makePort(endpointId: endpointB, recorder: recorder),
        makePort(endpointId: endpointA, recorder: recorder),
      ],
      clientIdentity: .init(clientId: "client-1", deviceName: "Mac")
    )
    await coordinator.waitUntilIdleForTests()

    let writes = await recorder.claimWrites
    #expect(writes == [
      .init(endpointId: endpointA, isPrimary: false),
      .init(endpointId: endpointB, isPrimary: true),
    ])
  }

  @Test func reconcileDoesNotEmitDuplicateWritesWhenStateAlreadyMatches() async throws {
    let endpointA = try #require(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))
    let endpointB = try #require(UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"))
    let recorder = ServerRoleRecorder()
    let coordinator = ServerRoleCoordinator()
    let plan = ServerRolePlan(
      enabledEndpointIds: [endpointA, endpointB],
      primaryEndpointId: endpointB
    )
    let ports = [
      makePort(endpointId: endpointA, recorder: recorder),
      makePort(endpointId: endpointB, recorder: recorder),
    ]

    await coordinator.submitPrimaryClaimPlan(
      plan,
      ports: ports,
      clientIdentity: .init(clientId: "client-1", deviceName: "Mac")
    )
    await coordinator.waitUntilIdleForTests()

    await coordinator.submitPrimaryClaimPlan(
      plan,
      ports: ports,
      clientIdentity: .init(clientId: "client-1", deviceName: "Mac")
    )
    await coordinator.waitUntilIdleForTests()

    let writes = await recorder.claimWrites
    #expect(writes.count == 2)
  }

  @Test func reconcileCoalescesRepeatedPlansToLatestDesiredState() async throws {
    let endpointA = try #require(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))
    let endpointB = try #require(UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"))
    let recorder = BlockingServerRoleRecorder()
    let coordinator = ServerRoleCoordinator()
    let ports = [
      makePort(endpointId: endpointA, recorder: recorder),
      makePort(endpointId: endpointB, recorder: recorder),
    ]
    let identity = ServerClientIdentity(clientId: "client-1", deviceName: "Mac")

    await coordinator.submitPrimaryClaimPlan(
      ServerRolePlan(
        enabledEndpointIds: [endpointA, endpointB],
        primaryEndpointId: endpointA
      ),
      ports: ports,
      clientIdentity: identity
    )
    await recorder.waitForFirstClaimWrite()

    await coordinator.submitPrimaryClaimPlan(
      ServerRolePlan(
        enabledEndpointIds: [endpointA, endpointB],
        primaryEndpointId: endpointB
      ),
      ports: ports,
      clientIdentity: identity
    )
    await recorder.releaseFirstClaimWrite()
    await coordinator.waitUntilIdleForTests()

    let finalAssignments = await recorder.lastAssignmentsByEndpoint
    #expect(finalAssignments == [
      endpointA: false,
      endpointB: true,
    ])
  }

  @Test func applyServerRoleChangeDemotesOthersBeforePromotingTarget() async throws {
    let endpointA = try #require(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))
    let endpointB = try #require(UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"))
    let recorder = ServerRoleRecorder()
    let coordinator = ServerRoleCoordinator()

    await coordinator.applyServerRoleChange(
      endpointId: endpointB,
      isPrimary: true,
      ports: [
        makePort(endpointId: endpointA, recorder: recorder),
        makePort(endpointId: endpointB, recorder: recorder),
      ]
    )

    let writes = await recorder.serverRoleWrites
    #expect(writes == [
      .init(endpointId: endpointA, isPrimary: false),
      .init(endpointId: endpointB, isPrimary: true),
    ])
  }

  private func makePort(endpointId: UUID, recorder: any ServerRoleRecording) -> ServerRolePort {
    ServerRolePort(
      endpointId: endpointId,
      client: ServerRoleClient(
        setServerRole: { isPrimary in
          await recorder.recordServerRole(endpointId: endpointId, isPrimary: isPrimary)
          return isPrimary
        },
        setClientPrimaryClaim: { _, isPrimary in
          await recorder.recordClaim(endpointId: endpointId, isPrimary: isPrimary)
        }
      )
    )
  }
}

private struct RecordedPrimaryClaimWrite: Equatable {
  let endpointId: UUID
  let isPrimary: Bool
}

private struct RecordedServerRoleWrite: Equatable {
  let endpointId: UUID
  let isPrimary: Bool
}

private protocol ServerRoleRecording: Actor {
  var lastAssignmentsByEndpoint: [UUID: Bool] { get async }
  func recordClaim(endpointId: UUID, isPrimary: Bool) async
  func recordServerRole(endpointId: UUID, isPrimary: Bool) async
}

private actor ServerRoleRecorder: ServerRoleRecording {
  private(set) var claimWrites: [RecordedPrimaryClaimWrite] = []
  private(set) var serverRoleWrites: [RecordedServerRoleWrite] = []
  private(set) var lastAssignmentsByEndpoint: [UUID: Bool] = [:]

  func recordClaim(endpointId: UUID, isPrimary: Bool) {
    claimWrites.append(.init(endpointId: endpointId, isPrimary: isPrimary))
    lastAssignmentsByEndpoint[endpointId] = isPrimary
  }

  func recordServerRole(endpointId: UUID, isPrimary: Bool) {
    serverRoleWrites.append(.init(endpointId: endpointId, isPrimary: isPrimary))
  }
}

private actor BlockingServerRoleRecorder: ServerRoleRecording {
  private(set) var claimWrites: [RecordedPrimaryClaimWrite] = []
  private(set) var serverRoleWrites: [RecordedServerRoleWrite] = []
  private(set) var lastAssignmentsByEndpoint: [UUID: Bool] = [:]

  private var hasBlockedFirstClaimWrite = false
  private var firstClaimWriteContinuation: CheckedContinuation<Void, Never>?
  private var releaseFirstClaimWriteContinuation: CheckedContinuation<Void, Never>?

  func waitForFirstClaimWrite() async {
    if hasBlockedFirstClaimWrite { return }
    await withCheckedContinuation { continuation in
      firstClaimWriteContinuation = continuation
    }
  }

  func releaseFirstClaimWrite() async {
    releaseFirstClaimWriteContinuation?.resume()
    releaseFirstClaimWriteContinuation = nil
  }

  func recordClaim(endpointId: UUID, isPrimary: Bool) async {
    claimWrites.append(.init(endpointId: endpointId, isPrimary: isPrimary))
    lastAssignmentsByEndpoint[endpointId] = isPrimary

    if !hasBlockedFirstClaimWrite {
      hasBlockedFirstClaimWrite = true
      firstClaimWriteContinuation?.resume()
      firstClaimWriteContinuation = nil
      await withCheckedContinuation { continuation in
        releaseFirstClaimWriteContinuation = continuation
      }
    }
  }

  func recordServerRole(endpointId: UUID, isPrimary: Bool) {
    serverRoleWrites.append(.init(endpointId: endpointId, isPrimary: isPrimary))
  }
}
