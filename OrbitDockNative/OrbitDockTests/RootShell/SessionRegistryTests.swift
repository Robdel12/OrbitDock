import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct SessionRegistryTests {
  @Test func promotingAndDemotingOnlyAffectsTargetHotSession() async throws {
    let registry = SessionRegistry()
    let endpointId = try #require(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"))
    let hot = ScopedSessionID(endpointId: endpointId, sessionId: "session-hot")
    let warm = ScopedSessionID(endpointId: endpointId, sessionId: "session-warm")

    await registry.promote(hot)

    #expect(await registry.isHot(hot))
    #expect(!(await registry.isHot(warm)))

    await registry.demote(hot)

    #expect(await registry.hotSessionIDsSnapshot().isEmpty)
  }

  @Test func promotingBeyondTheHotTierLimitEvictsTheLeastRecentSession() async throws {
    let registry = SessionRegistry(hotSessionLimit: 2)
    let endpointId = try #require(UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"))
    let first = ScopedSessionID(endpointId: endpointId, sessionId: "session-a")
    let second = ScopedSessionID(endpointId: endpointId, sessionId: "session-b")
    let third = ScopedSessionID(endpointId: endpointId, sessionId: "session-c")

    await registry.promote(first)
    await registry.promote(second)
    await registry.promote(third)

    #expect(!(await registry.isHot(first)))
    #expect(await registry.isHot(second))
    #expect(await registry.isHot(third))
    #expect(await registry.hotSessionOrderSnapshot() == [second.scopedID, third.scopedID])
  }

  @Test func promotingAHotSessionAgainMovesItToTheMostRecentSlot() async throws {
    let registry = SessionRegistry(hotSessionLimit: 2)
    let endpointId = try #require(UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"))
    let first = ScopedSessionID(endpointId: endpointId, sessionId: "session-a")
    let second = ScopedSessionID(endpointId: endpointId, sessionId: "session-b")

    await registry.promote(first)
    await registry.promote(second)
    await registry.promote(first)

    #expect(await registry.hotSessionOrderSnapshot() == [second.scopedID, first.scopedID])
    #expect(await registry.hotSessionIDsSnapshot() == Set([first.scopedID, second.scopedID]))
  }
}
