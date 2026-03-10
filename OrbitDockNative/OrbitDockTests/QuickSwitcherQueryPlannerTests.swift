import Testing
@testable import OrbitDock

struct QuickSwitcherQueryPlannerTests {
  @Test func trimsAndLowercasesQueryBeforeClassifying() {
    let plan = QuickSwitcherQueryPlanner.plan(searchText: "  Claude Printer  ")

    #expect(plan.normalizedQuery == "claude printer")
    expectMode(plan.mode, equals: .quickLaunch(.claude))
  }

  @Test func recognizesClaudeQuickLaunchShorthands() {
    expectMode(QuickSwitcherQueryPlanner.plan(searchText: "new c").mode, equals: .quickLaunch(.claude))
    expectMode(QuickSwitcherQueryPlanner.plan(searchText: "NC").mode, equals: .quickLaunch(.claude))
    expectMode(QuickSwitcherQueryPlanner.plan(searchText: "claude").mode, equals: .quickLaunch(.claude))
  }

  @Test func recognizesCodexQuickLaunchShorthands() {
    expectMode(QuickSwitcherQueryPlanner.plan(searchText: "new o").mode, equals: .quickLaunch(.codex))
    expectMode(QuickSwitcherQueryPlanner.plan(searchText: "NO").mode, equals: .quickLaunch(.codex))
    expectMode(QuickSwitcherQueryPlanner.plan(searchText: "codex fixes").mode, equals: .quickLaunch(.codex))
  }

  @Test func plainNewQueriesStayInStandardMode() {
    expectMode(QuickSwitcherQueryPlanner.plan(searchText: "new").mode, equals: .standard)
    expectMode(QuickSwitcherQueryPlanner.plan(searchText: "n").mode, equals: .standard)
    expectMode(QuickSwitcherQueryPlanner.plan(searchText: "new printer").mode, equals: .standard)
  }

  @Test func unrelatedQueriesStayInStandardMode() {
    let plan = QuickSwitcherQueryPlanner.plan(searchText: "printer fixes")

    expectMode(plan.mode, equals: .standard)
    #expect(plan.normalizedQuery == "printer fixes")
  }

  private func expectMode(_ actual: QuickSwitcherSearchMode, equals expected: QuickSwitcherSearchMode) {
    switch (actual, expected) {
      case (.standard, .standard):
        #expect(Bool(true))
      case let (.quickLaunch(actualProvider), .quickLaunch(expectedProvider)):
        #expect(actualProvider == expectedProvider)
      default:
        Issue.record("Expected mode \(expected), got \(actual)")
    }
  }
}
