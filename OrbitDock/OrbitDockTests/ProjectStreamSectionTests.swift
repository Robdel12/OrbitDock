import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct ProjectStreamSectionTests {
  @Test func makeProjectGroupsSortsByRecentActivity() {
    let alphaPath = "/Users/dev/alpha"
    let betaPath = "/Users/dev/beta"
    let sessions = [
      makeProjectSession(id: "alpha", projectPath: alphaPath, projectName: "Alpha", lastActivityAt: 100),
      makeProjectSession(id: "beta", projectPath: betaPath, projectName: "Beta", lastActivityAt: 300),
    ]

    let groups = ProjectStreamSection.makeProjectGroups(from: sessions, sort: .recent)

    #expect(groups.map(\.projectPath) == [betaPath, alphaPath])
  }

  @Test func makeProjectGroupsHonorsPreferredOrderBeforeSort() {
    let alphaPath = "/Users/dev/alpha"
    let betaPath = "/Users/dev/beta"
    let gammaPath = "/Users/dev/gamma"
    let sessions = [
      makeProjectSession(id: "alpha", projectPath: alphaPath, projectName: "Alpha", lastActivityAt: 400),
      makeProjectSession(id: "beta", projectPath: betaPath, projectName: "Beta", lastActivityAt: 500),
      makeProjectSession(id: "gamma", projectPath: gammaPath, projectName: "Gamma", lastActivityAt: 300),
    ]

    let preferred = [groupKey(for: gammaPath), groupKey(for: alphaPath)]
    let groups = ProjectStreamSection.makeProjectGroups(
      from: sessions,
      sort: .recent,
      preferredOrder: preferred
    )

    #expect(groups.map(\.projectPath) == [gammaPath, alphaPath, betaPath])
  }

  @Test func makeProjectGroupsExcludesHiddenGroupKeys() {
    let alphaPath = "/Users/dev/alpha"
    let betaPath = "/Users/dev/beta"
    let sessions = [
      makeProjectSession(id: "alpha", projectPath: alphaPath, projectName: "Alpha", lastActivityAt: 100),
      makeProjectSession(id: "beta", projectPath: betaPath, projectName: "Beta", lastActivityAt: 300),
    ]

    let hidden = Set([groupKey(for: betaPath)])
    let groups = ProjectStreamSection.makeProjectGroups(
      from: sessions,
      sort: .recent,
      hiddenGroupKeys: hidden
    )

    #expect(groups.map(\.projectPath) == [alphaPath])
  }

  @Test func keyboardNavigableSessionsUsesManualProjectOrder() {
    let alphaPath = "/Users/dev/alpha"
    let betaPath = "/Users/dev/beta"
    let sessions = [
      makeProjectSession(id: "alpha", projectPath: alphaPath, projectName: "Alpha", lastActivityAt: 500),
      makeProjectSession(id: "beta", projectPath: betaPath, projectName: "Beta", lastActivityAt: 300),
    ]

    let ordered = ProjectStreamSection.keyboardNavigableSessions(
      from: sessions,
      filter: .all,
      sort: .recent,
      providerFilter: .all,
      projectGroupOrder: [groupKey(for: betaPath), groupKey(for: alphaPath)]
    )

    #expect(ordered.map(\.projectPath) == [betaPath, alphaPath])
  }

  @Test func keyboardNavigableSessionsCanIgnoreManualOrderWhenUsingSortOrderMode() {
    let alphaPath = "/Users/dev/alpha"
    let betaPath = "/Users/dev/beta"
    let sessions = [
      makeProjectSession(id: "alpha", projectPath: alphaPath, projectName: "Alpha", lastActivityAt: 500),
      makeProjectSession(id: "beta", projectPath: betaPath, projectName: "Beta", lastActivityAt: 300),
    ]

    let ordered = ProjectStreamSection.keyboardNavigableSessions(
      from: sessions,
      filter: .all,
      sort: .recent,
      providerFilter: .all,
      projectGroupOrder: [groupKey(for: betaPath), groupKey(for: alphaPath)],
      useCustomProjectOrder: false
    )

    #expect(ordered.map(\.projectPath) == [alphaPath, betaPath])
  }
}

private func groupKey(for projectPath: String) -> String {
  "single-endpoint::\(projectPath)"
}

private func makeProjectSession(
  id: String,
  projectPath: String,
  projectName: String,
  lastActivityAt: TimeInterval
) -> Session {
  Session(
    id: id,
    projectPath: projectPath,
    projectName: projectName,
    status: .active,
    workStatus: .working,
    startedAt: Date(timeIntervalSince1970: 0),
    lastActivityAt: Date(timeIntervalSince1970: lastActivityAt)
  )
}
