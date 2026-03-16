import Foundation
@testable import OrbitDock
import Testing

struct ProjectPickerPlannerTests {
  @Test func groupedRecentProjectsGroupsReposAndWorktreesDeterministically() {
    let projects = [
      ServerRecentProject(
        path: "/Users/robert/Developer/printer/.orbitdock-worktrees/branch-b",
        sessionCount: 2,
        lastActive: "2026-03-10T02:00:00Z"
      ),
      ServerRecentProject(
        path: "/Users/robert/Developer/printer",
        sessionCount: 4,
        lastActive: "2026-03-10T01:00:00Z"
      ),
      ServerRecentProject(
        path: "/Users/robert/Developer/printer/.orbitdock-worktrees/branch-a",
        sessionCount: 1,
        lastActive: "2026-03-10T03:00:00Z"
      ),
      ServerRecentProject(
        path: "/Users/robert/Developer/router",
        sessionCount: 3,
        lastActive: "2026-03-09T12:00:00Z"
      ),
    ]

    let groups = ProjectPickerPlanner.groupedRecentProjects(from: projects)

    #expect(groups.map(\.repoPath) == [
      "/Users/robert/Developer/printer",
      "/Users/robert/Developer/router",
    ])
    #expect(groups.first?.totalSessionCount == 7)
    #expect(groups.first?.repoProject?.path == "/Users/robert/Developer/printer")
    #expect(groups.first?.worktrees.map(\.branchPath) == ["branch-a", "branch-b"])
  }

  @Test func displayPathCollapsesUserHomePrefix() {
    #expect(ProjectPickerPlanner.displayPath("/Users/robert/Developer/printer") == "~/Developer/printer")
    #expect(ProjectPickerPlanner.displayPath("") == "~")
    #expect(ProjectPickerPlanner.displayPath("/tmp/printer") == "/tmp/printer")
  }

  @Test func worktreeRelativePathUsesRepoNameAndBranchPath() {
    let worktree = ProjectPickerRecentWorktreeProject(
      project: ServerRecentProject(
        path: "/Users/robert/Developer/printer/.orbitdock-worktrees/branch-a",
        sessionCount: 1,
        lastActive: nil
      ),
      repoPath: "/Users/robert/Developer/printer",
      branchPath: "branch-a"
    )

    #expect(ProjectPickerPlanner.worktreeRelativePath(worktree) == "printer/.orbitdock-worktrees/branch-a")
    #expect(ProjectPickerPlanner.sessionCountLabel(1) == "1 session")
    #expect(ProjectPickerPlanner.sessionCountLabel(2) == "2 sessions")
  }

  @Test func browseResponsePushesHistoryOnlyForNestedBrowseRequests() {
    let entries = [
      ServerDirectoryEntry(name: "printer", isDir: true, isGit: true),
    ]

    let rootProjection = ProjectPickerPlanner.applyBrowseResponse(
      requestedPath: nil,
      currentBrowsePath: "",
      browseHistory: [],
      browsedPath: "/Users/robert/Developer",
      entries: entries
    )

    #expect(rootProjection.browseHistory.isEmpty)
    #expect(rootProjection.currentBrowsePath == "/Users/robert/Developer")

    let nestedProjection = ProjectPickerPlanner.applyBrowseResponse(
      requestedPath: "/Users/robert/Developer/printer",
      currentBrowsePath: "/Users/robert/Developer",
      browseHistory: rootProjection.browseHistory,
      browsedPath: "/Users/robert/Developer/printer",
      entries: entries
    )

    #expect(nestedProjection.browseHistory == ["/Users/robert/Developer"])
    #expect(ProjectPickerPlanner.canNavigateBack(nestedProjection.browseHistory))
  }

  @Test func navigateBackResponsePopsOneHistoryLevel() {
    let entries = [
      ServerDirectoryEntry(name: "router", isDir: true, isGit: false),
    ]

    let projection = ProjectPickerPlanner.applyNavigateBackResponse(
      browseHistory: ["/Users/robert", "/Users/robert/Developer"],
      browsedPath: "/Users/robert/Developer",
      entries: entries
    )

    #expect(projection?.browseHistory == ["/Users/robert"])
    #expect(projection?.currentBrowsePath == "/Users/robert/Developer")
    #expect(projection?.directoryEntries.map(\.name) == ["router"])
  }

  @Test func childPathAndResetBrowseProjectionStayDeterministic() {
    #expect(ProjectPickerPlanner.childPath(entryName: "printer", currentBrowsePath: "") == "printer")
    #expect(
      ProjectPickerPlanner.childPath(
        entryName: "printer",
        currentBrowsePath: "/Users/robert/Developer"
      ) == "/Users/robert/Developer/printer"
    )

    let projection = ProjectPickerPlanner.resetBrowseProjection()
    #expect(projection.currentBrowsePath.isEmpty)
    #expect(projection.browseHistory.isEmpty)
    #expect(projection.directoryEntries.isEmpty)
  }

  @Test func requestGuardRejectsStaleRequestIdsAndEndpointMismatches() {
    let requestId = UUID()
    let endpointId = UUID()

    #expect(
      ProjectPickerPlanner.shouldApplyResponse(
        requestId: requestId,
        activeRequestId: requestId,
        requestEndpointId: endpointId,
        activeEndpointId: endpointId
      )
    )

    #expect(
      !ProjectPickerPlanner.shouldApplyResponse(
        requestId: requestId,
        activeRequestId: UUID(),
        requestEndpointId: endpointId,
        activeEndpointId: endpointId
      )
    )

    #expect(
      !ProjectPickerPlanner.shouldApplyResponse(
        requestId: requestId,
        activeRequestId: requestId,
        requestEndpointId: endpointId,
        activeEndpointId: UUID()
      )
    )
  }
}
