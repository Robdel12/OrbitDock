import Testing
@testable import OrbitDock

@MainActor
struct QuickSwitcherRowPresentationTests {
  @Test func displayPathCollapsesUserHomePrefix() {
    #expect(QuickSwitcherRowPresentation.displayPath("/Users/robert/Developer/OrbitDock") == "~/Developer/OrbitDock")
    #expect(QuickSwitcherRowPresentation.displayPath("") == "~")
    #expect(QuickSwitcherRowPresentation.displayPath("/tmp/repo") == "/tmp/repo")
  }

  @Test func projectNameFallsBackFromExplicitProjectNameToPathLeaf() {
    let namedSession = Session(
      id: "1",
      projectPath: "/tmp/repo",
      projectName: "OrbitDock",
      branch: nil,
      model: nil,
      contextLabel: nil,
      transcriptPath: nil,
      status: .active,
      workStatus: .unknown,
      startedAt: nil,
      endedAt: nil,
      endReason: nil,
      totalTokens: 0,
      totalCostUSD: 0,
      lastActivityAt: nil,
      lastTool: nil,
      lastToolAt: nil,
      promptCount: 0,
      toolCount: 0,
      terminalSessionId: nil,
      terminalApp: nil
    )
    #expect(QuickSwitcherRowPresentation.projectName(for: namedSession) == "OrbitDock")

    let unnamedSession = Session(
      id: "2",
      projectPath: "/tmp/worktree/repo-name",
      projectName: nil,
      branch: nil,
      model: nil,
      contextLabel: nil,
      transcriptPath: nil,
      status: .active,
      workStatus: .unknown,
      startedAt: nil,
      endedAt: nil,
      endReason: nil,
      totalTokens: 0,
      totalCostUSD: 0,
      lastActivityAt: nil,
      lastTool: nil,
      lastToolAt: nil,
      promptCount: 0,
      toolCount: 0,
      terminalSessionId: nil,
      terminalApp: nil
    )
    #expect(QuickSwitcherRowPresentation.projectName(for: unnamedSession) == "repo-name")
  }

  @Test func activityPresentationPrefersSessionContextForPermissionAndWorkingStates() {
    var session = Session(
      id: "1",
      projectPath: "/tmp/repo",
      projectName: nil,
      branch: nil,
      model: nil,
      contextLabel: nil,
      transcriptPath: nil,
      status: .active,
      workStatus: .unknown,
      startedAt: nil,
      endedAt: nil,
      endReason: nil,
      totalTokens: 0,
      totalCostUSD: 0,
      lastActivityAt: nil,
      lastTool: "Bash",
      lastToolAt: nil,
      promptCount: 0,
      toolCount: 0,
      terminalSessionId: nil,
      terminalApp: nil
    )
    session.pendingToolName = "Edit"

    #expect(QuickSwitcherRowPresentation.activityText(for: session, status: .permission) == "Edit")
    #expect(QuickSwitcherRowPresentation.activityIcon(for: session, status: .permission) == "lock.fill")
    #expect(QuickSwitcherRowPresentation.activityText(for: session, status: .working) == "Bash")
    #expect(QuickSwitcherRowPresentation.activityIcon(for: session, status: .working) == ToolCardStyle.icon(for: "Bash"))
    #expect(QuickSwitcherRowPresentation.activityText(for: session, status: .reply) == "Ready")
    #expect(QuickSwitcherRowPresentation.activityText(for: session, status: .ended) == "Ended")
  }
}
