import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct AppRouterTests {
  @Test func selectSessionDoesNotRewriteTheSameRoute() throws {
    let router = AppRouter()
    let ref = try SessionRef(
      endpointId: #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")),
      sessionId: "session-1"
    )

    router.selectSession(ref, source: .external)
    let firstRoute = router.route

    router.selectSession(ref, source: .external)

    #expect(router.route == firstRoute)
    #expect(router.selectedSessionRef == ref)
  }

  @Test func goToDashboardDoesNotRewriteMissionControlRoute() {
    let router = AppRouter()
    router.route = .dashboard(.missionControl)

    router.goToDashboard(source: .commandMenu)

    #expect(router.route == .dashboard(.missionControl))
  }
}
