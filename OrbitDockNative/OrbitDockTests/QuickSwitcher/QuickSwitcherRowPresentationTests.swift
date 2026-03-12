import Foundation
import Foundation
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
    var namedSession = Session(
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
    namedSession.endpointId = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
    #expect(QuickSwitcherRowPresentation.projectName(for: SessionSummary(session: namedSession)) == "OrbitDock")

    var unnamedSession = Session(
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
    unnamedSession.endpointId = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
    #expect(QuickSwitcherRowPresentation.projectName(for: SessionSummary(session: unnamedSession)) == "repo-name")
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

    let summary = SessionSummary(session: session)
    #expect(QuickSwitcherRowPresentation.activityText(for: summary, status: .permission) == "Edit")
    #expect(QuickSwitcherRowPresentation.activityIcon(for: summary, status: .permission) == "lock.fill")
    #expect(QuickSwitcherRowPresentation.activityText(for: summary, status: .working) == "Bash")
    #expect(QuickSwitcherRowPresentation.activityIcon(for: summary, status: .working) == ToolCardStyle.icon(for: "Bash"))
    #expect(QuickSwitcherRowPresentation.activityText(for: summary, status: .reply) == "Ready")
    #expect(QuickSwitcherRowPresentation.activityText(for: summary, status: .ended) == "Ended")
  }
}
