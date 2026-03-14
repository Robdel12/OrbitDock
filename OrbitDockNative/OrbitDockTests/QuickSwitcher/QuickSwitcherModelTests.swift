import Foundation
import Testing
@testable import OrbitDock

@MainActor
struct QuickSwitcherModelTests {
  @Test func applySearchTransitionCapturesScopedTargetAndQuickLaunchMode() {
    var state = QuickSwitcherState()
    let session = makeSession(id: "one")

    state.applySearchTransition(
      QuickSwitcherSearchTransition(
        targetSession: session,
        selectedIndex: 0,
        hoveredIndex: nil,
        mode: .quickLaunch(.claude),
        shouldLoadRecentProjects: true
      )
    )

    #expect(state.targetSessionScopedID == session.scopedID)
    #expect(state.quickLaunchMode == .claude)
  }

  @Test func finishRecentProjectsLoadAppliesOnlyLatestMatchingRequest() {
    var state = QuickSwitcherState()
    let matchingRequest = UUID()
    let staleRequest = UUID()
    let endpointId = UUID()
    let projects = [ServerRecentProject(path: "/tmp/demo", sessionCount: 3, lastActive: nil)]

    state.beginRecentProjectsLoad(requestId: matchingRequest)
    state.finishRecentProjectsLoad(
      requestId: staleRequest,
      endpointId: endpointId,
      activeEndpointId: endpointId,
      projects: projects
    )

    #expect(state.recentProjects.isEmpty)
    #expect(state.isLoadingProjects)

    state.finishRecentProjectsLoad(
      requestId: matchingRequest,
      endpointId: endpointId,
      activeEndpointId: endpointId,
      projects: projects
    )

    #expect(state.recentProjects.count == 1)
    #expect(state.recentProjects.first?.path == "/tmp/demo")
    #expect(state.recentProjects.first?.sessionCount == 3)
    #expect(state.isLoadingProjects == false)
  }

  @Test func viewStateBuildsProjectionAndSelectionFromExplicitState() {
    var state = QuickSwitcherState()
    state.searchText = "rename"
    state.targetSessionScopedID = makeSession(id: "two").scopedID

    let sessions = [
      makeSession(id: "one"),
      makeSession(id: "two"),
    ]

    let viewState = QuickSwitcherViewState.make(
      sessions: sessions,
      state: state,
      selectedSessionRef: sessions[0].sessionRef,
      isCompactLayout: false
    )

    #expect(viewState.currentSession?.sessionId == "one")
    #expect(viewState.targetSession?.sessionId == "two")
    #expect(viewState.searchQuery == "rename")
    #expect(viewState.filteredCommands.contains(where: { $0.name.lowercased().contains("rename") }))
  }

  private func makeSession(id: String) -> RootSessionNode {
    var session = Session(
      id: id,
      projectPath: "/tmp/\(id)",
      status: .active,
      workStatus: .waiting,
      totalTokens: 0,
      totalCostUSD: 0
    )
    session.endpointId = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
    session.endpointName = "Primary"
    session.endpointConnectionStatus = .connected
    return makeRootSessionNode(from: session)
  }
}
