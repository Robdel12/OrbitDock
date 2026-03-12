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
}
