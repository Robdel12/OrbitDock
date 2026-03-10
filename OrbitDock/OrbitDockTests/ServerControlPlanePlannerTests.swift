import Foundation
@testable import OrbitDock
import Testing

struct ServerControlPlanePlannerTests {
  @Test func primaryClaimPlannerEmitsExpectedAssignmentsForPrimaryEndpoint() throws {
    let endpointA = try #require(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))
    let endpointB = try #require(UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"))

    let assignments = ServerPrimaryClaimPlanner.desiredAssignments(
      enabledEndpointIds: [endpointA, endpointB],
      primaryEndpointId: endpointB
    )

    #expect(assignments == [
      endpointA: false,
      endpointB: true,
    ])
  }

  @Test func primaryClaimPlannerIgnoresRemovedEndpointsWhenDiffing() throws {
    let endpointA = try #require(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))
    let endpointB = try #require(UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"))
    let removedEndpoint = try #require(UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc"))

    let updates = ServerPrimaryClaimPlanner.updates(
      enabledEndpointIds: [endpointA, endpointB],
      primaryEndpointId: endpointA,
      previousAssignments: [
        endpointA: false,
        endpointB: true,
        removedEndpoint: true,
      ]
    )

    #expect(updates == [
      ServerPrimaryClaimUpdate(endpointId: endpointA, isPrimary: true),
      ServerPrimaryClaimUpdate(endpointId: endpointB, isPrimary: false),
    ])
  }

  @Test func primaryClaimPlannerProducesStableEndpointOrder() throws {
    let endpointA = try #require(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))
    let endpointB = try #require(UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"))

    let updates = ServerPrimaryClaimPlanner.updates(
      enabledEndpointIds: [endpointA, endpointB],
      primaryEndpointId: endpointB,
      previousAssignments: [:]
    )

    #expect(updates == [
      ServerPrimaryClaimUpdate(endpointId: endpointA, isPrimary: false),
      ServerPrimaryClaimUpdate(endpointId: endpointB, isPrimary: true),
    ])
  }
}
