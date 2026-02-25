import Foundation
@testable import OrbitDock
import Testing

struct ServerAppStateCacheKeyTests {
  @Test func cacheKeysAreEndpointScoped() throws {
    let endpointA = try #require(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
    let endpointB = try #require(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"))

    let codexA = ServerAppState.codexModelsCacheKey(endpointId: endpointA)
    let codexB = ServerAppState.codexModelsCacheKey(endpointId: endpointB)
    let sessionsA = ServerAppState.sessionsCacheKey(endpointId: endpointA)
    let sessionsB = ServerAppState.sessionsCacheKey(endpointId: endpointB)

    #expect(codexA != codexB)
    #expect(sessionsA != sessionsB)
    #expect(codexA.contains(endpointA.uuidString))
    #expect(sessionsB.contains(endpointB.uuidString))
  }
}
