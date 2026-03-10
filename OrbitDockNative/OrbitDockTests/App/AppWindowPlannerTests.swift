import SwiftUI
import Testing
@testable import OrbitDock

@MainActor
struct AppWindowPlannerTests {
  @Test func contentDestinationPrefersSetupWhenServerIsNotConfigured() {
    let ref = SessionRef(endpointId: UUID(), sessionId: "session-1")

    let destination = AppWindowPlanner.contentDestination(
      connectedRuntimeCount: 0,
      installState: .notConfigured,
      selectedSessionRef: ref
    )

    #expect(destination == .setup)
  }

  @Test func contentDestinationUsesSelectedSessionWhenSetupIsNotVisible() {
    let ref = SessionRef(endpointId: UUID(), sessionId: "session-2")

    let destination = AppWindowPlanner.contentDestination(
      connectedRuntimeCount: 1,
      installState: .running,
      selectedSessionRef: ref
    )

    #expect(destination == .session(ref))
  }

  @Test func contentDestinationFallsBackToDashboardWithoutSelection() {
    let destination = AppWindowPlanner.contentDestination(
      connectedRuntimeCount: 1,
      installState: .running,
      selectedSessionRef: nil
    )

    #expect(destination == .dashboard)
  }

  @Test func focusedWindowUpdateTracksForegroundWindowAndClearsOnlyTheCurrentOne() {
    let windowID = UUID()
    let otherWindowID = UUID()

    #expect(
      AppWindowPlanner.focusedWindowUpdate(
        currentFocusedWindowID: otherWindowID,
        windowID: windowID,
        scenePhase: .active
      ) == windowID
    )

    #expect(
      AppWindowPlanner.focusedWindowUpdate(
        currentFocusedWindowID: windowID,
        windowID: windowID,
        scenePhase: .background
      ) == nil
    )

    #expect(
      AppWindowPlanner.focusedWindowUpdate(
        currentFocusedWindowID: otherWindowID,
        windowID: windowID,
        scenePhase: .inactive
      ) == otherWindowID
    )
  }

  @Test func externalSelectionOnlyRoutesCommandsForActiveWindows() {
    let endpointID = UUID()

    let activeSelection = AppWindowPlanner.externalSelection(
      command: .selectSession(sessionId: "session-3", endpointId: endpointID),
      scenePhase: .active
    )
    #expect(activeSelection?.sessionID == "session-3")
    #expect(activeSelection?.endpointID == endpointID)

    let backgroundSelection = AppWindowPlanner.externalSelection(
      command: .selectSession(sessionId: "session-3", endpointId: endpointID),
      scenePhase: .background
    )
    #expect(backgroundSelection == nil)
  }
}
