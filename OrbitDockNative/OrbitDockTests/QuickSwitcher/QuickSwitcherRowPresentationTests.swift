import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct QuickSwitcherRowPresentationTests {
  @Test func displayPathCollapsesUserHomePrefix() {
    #expect(QuickSwitcherRowPresentation.displayPath("/Users/robert/Developer/OrbitDock") == "~/Developer/OrbitDock")
    #expect(QuickSwitcherRowPresentation.displayPath("") == "~")
    #expect(QuickSwitcherRowPresentation.displayPath("/tmp/repo") == "/tmp/repo")
  }

  @Test func projectNameFallsBackFromExplicitProjectNameToPathLeaf() {
    let namedSession = makeRootSessionNode(from: Session(
      id: "1",
      endpointId: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"),
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
    ))
    #expect(QuickSwitcherRowPresentation.projectName(for: namedSession) == "OrbitDock")

    let unnamedSession = makeRootSessionNode(from: Session(
      id: "2",
      endpointId: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"),
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
    ))
    #expect(QuickSwitcherRowPresentation.projectName(for: unnamedSession) == "repo-name")
  }

  @Test func activityPresentationPrefersSessionContextForPermissionAndWorkingStates() {
    let session = makeRootSessionNode(from: Session(
      id: "1",
      endpointId: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"),
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
      terminalApp: nil,
      pendingToolName: "Edit"
    ))

    #expect(QuickSwitcherRowPresentation.activityText(for: session, status: .permission) == "Edit")
    #expect(QuickSwitcherRowPresentation.activityIcon(for: session, status: .permission) == "lock.fill")
    #expect(QuickSwitcherRowPresentation.activityText(for: session, status: .working) == "Edit")
    #expect(QuickSwitcherRowPresentation.activityIcon(for: session, status: .working) == ToolCardStyle
      .icon(for: "Edit"))
    #expect(QuickSwitcherRowPresentation.activityText(for: session, status: .reply) == "Ready")
    #expect(QuickSwitcherRowPresentation.activityText(for: session, status: .ended) == "Ended")
  }
}
