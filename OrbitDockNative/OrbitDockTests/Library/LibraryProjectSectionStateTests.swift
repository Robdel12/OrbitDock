import Foundation
import Testing
@testable import OrbitDock

@MainActor
struct LibraryProjectSectionStateTests {
  @Test func buildsBadgesAndCachedArchiveStateFromProjectGroup() {
    let endpointID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    let sessions = [
      makeSession(
        id: "live",
        endpointId: endpointID,
        endpointName: "Local",
        provider: .claude,
        projectPath: "/tmp/printer",
        status: .active,
        totalTokens: 1_400,
        totalCostUSD: 1.25,
        connectionStatus: .connected
      ),
      makeSession(
        id: "cached",
        endpointId: endpointID,
        endpointName: "Local",
        provider: .claude,
        projectPath: "/tmp/printer",
        status: .active,
        totalTokens: 600,
        totalCostUSD: 0.50,
        connectionStatus: .disconnected
      ),
    ]

    let group = try! #require(
      LibraryArchivePlanner.projectGroups(
        sessions: sessions,
        sort: .recent
      ).first
    )

    let state = LibraryProjectSectionState.build(group: group)

    #expect(
      state.badges.map(badgeDescription) == [
        "live:1",
        "cached:1",
        "cost:$1.75",
        "tokens:2.0k",
      ]
    )
  }

  @Test func limitsVisibleEndpointFacetsAndReportsOverflowCount() {
    let endpointIDs = (0..<5).map { index in
      UUID(uuidString: String(format: "%08X-AAAA-AAAA-AAAA-AAAAAAAAAAAA", index + 1))!
    }

    let sessions = endpointIDs.enumerated().map { index, endpointId in
      makeSession(
        id: "session-\(index)",
        endpointId: endpointId,
        endpointName: "Endpoint \(index)",
        provider: .claude,
        projectPath: "/tmp/printer",
        status: .ended
      )
    }

    let group = try! #require(
      LibraryArchivePlanner.projectGroups(
        sessions: sessions,
        sort: .recent
      ).first
    )

    let state = LibraryProjectSectionState.build(group: group)

    #expect(state.visibleEndpointFacetCount == 3)
    #expect(state.hiddenEndpointFacetCount == 2)
    #expect(state.archiveSectionTitle == "Archive")
  }

  private func badgeDescription(_ badge: LibraryProjectSectionBadge) -> String {
    switch badge {
      case let .live(count):
        "live:\(count)"
      case let .cached(count):
        "cached:\(count)"
      case let .cost(value):
        "cost:\(value)"
      case let .tokens(value):
        "tokens:\(value)"
    }
  }

  private func makeSession(
    id: String,
    endpointId: UUID,
    endpointName: String,
    provider: Provider,
    projectPath: String,
    status: Session.SessionStatus,
    totalTokens: Int = 0,
    totalCostUSD: Double = 0,
    connectionStatus: ConnectionStatus? = nil
  ) -> RootSessionNode {
    RootSessionNode(session: Session(
      id: id,
      endpointId: endpointId,
      endpointName: endpointName,
      endpointConnectionStatus: connectionStatus,
      projectPath: projectPath,
      projectName: URL(fileURLWithPath: projectPath).lastPathComponent,
      status: status,
      workStatus: .waiting,
      totalTokens: totalTokens,
      totalCostUSD: totalCostUSD,
      provider: provider
    ))
  }
}
