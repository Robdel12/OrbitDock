import Foundation
import Testing
@testable import OrbitDock

@MainActor
struct QuickSwitcherSelectionResolverTests {
  @Test func quickLaunchSelectionPrefersProjectIndexes() {
    let selection = QuickSwitcherSelectionResolver.selectedKind(
      selectedIndex: 1,
      isQuickLaunchMode: true,
      quickLaunchProjectCount: 3,
      commandCount: 2,
      dashboardIndex: 2,
      sessionStartIndex: 3,
      visibleSessionCount: 4
    )

    #expect(selection == .quickLaunchProject(index: 1))
  }

  @Test func commandSelectionUsesCommandRangeBeforeDashboard() {
    let selection = QuickSwitcherSelectionResolver.selectedKind(
      selectedIndex: 1,
      isQuickLaunchMode: false,
      quickLaunchProjectCount: 0,
      commandCount: 3,
      dashboardIndex: 3,
      sessionStartIndex: 4,
      visibleSessionCount: 4
    )

    #expect(selection == .command(index: 1))
  }

  @Test func dashboardSelectionResolvesExplicitDashboardIndex() {
    let selection = QuickSwitcherSelectionResolver.selectedKind(
      selectedIndex: 3,
      isQuickLaunchMode: false,
      quickLaunchProjectCount: 0,
      commandCount: 3,
      dashboardIndex: 3,
      sessionStartIndex: 4,
      visibleSessionCount: 4
    )

    #expect(selection == .dashboard)
  }

  @Test func sessionSelectionResolvesRelativeIndex() {
    let selection = QuickSwitcherSelectionResolver.selectedKind(
      selectedIndex: 6,
      isQuickLaunchMode: false,
      quickLaunchProjectCount: 0,
      commandCount: 2,
      dashboardIndex: 2,
      sessionStartIndex: 3,
      visibleSessionCount: 5
    )

    #expect(selection == .session(index: 3))
  }

  @Test func selectionFallsBackToNoneWhenOutOfBounds() {
    let selection = QuickSwitcherSelectionResolver.selectedKind(
      selectedIndex: 9,
      isQuickLaunchMode: false,
      quickLaunchProjectCount: 0,
      commandCount: 2,
      dashboardIndex: 2,
      sessionStartIndex: 3,
      visibleSessionCount: 4
    )

    #expect(selection == .none)
  }

  @Test func commandTargetSessionPrefersCurrentThenExplicitThenFallback() {
    let fallback = makeSession(id: "fallback")
    let explicit = makeSession(id: "explicit")
    let current = makeSession(id: "current")

    #expect(
      QuickSwitcherSelectionResolver.commandTargetSession(
        currentSession: current,
        explicitTargetSession: explicit,
        fallbackVisibleSession: fallback
      )?.id == "current"
    )

    #expect(
      QuickSwitcherSelectionResolver.commandTargetSession(
        currentSession: nil,
        explicitTargetSession: explicit,
        fallbackVisibleSession: fallback
      )?.id == "explicit"
    )

    #expect(
      QuickSwitcherSelectionResolver.commandTargetSession(
        currentSession: nil,
        explicitTargetSession: nil,
        fallbackVisibleSession: fallback
      )?.id == "fallback"
    )
  }

  private func makeSession(id: String) -> SessionSummary {
    SessionSummary(session: Session(
      id: id,
      projectPath: "/tmp/\(id)",
      status: .active,
      workStatus: .waiting,
      totalTokens: 0,
      totalCostUSD: 0
    ))
  }
}
