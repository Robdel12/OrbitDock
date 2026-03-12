import Foundation
@testable import OrbitDock

enum RootShellLoadFixture {
  static let endpointID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
  static let endpointName = "Load Test Endpoint"

  static func passiveSessions(count: Int) -> [ServerSessionListItem] {
    var sessions: [ServerSessionListItem] = []
    sessions.reserveCapacity(count)

    for index in 0..<count {
      let session = makeSessionListItem(
        id: "passive-\(index)",
        title: "Passive Session \(index)",
        projectName: "Project \(index % 8)",
        branch: "branch-\(index % 5)",
        status: .active,
        workStatus: .reply,
        codexIntegrationMode: .passive,
        unreadCount: UInt64(index % 3),
        totalTokens: UInt64(1_000 + index),
        totalCostUSD: Double(index) * 0.01
      )
      sessions.append(session)
    }
    return sessions
  }

  static func updatedPassiveSessions(count: Int) -> [ServerSessionListItem] {
    var sessions: [ServerSessionListItem] = []
    sessions.reserveCapacity(count)

    for index in 0..<count {
      let session = makeSessionListItem(
        id: "passive-\(index)",
        title: "Passive Session \(index)",
        projectName: "Project \(index % 8)",
        branch: "branch-\(index % 5)",
        status: .active,
        workStatus: index.isMultiple(of: 2) ? .working : .reply,
        codexIntegrationMode: .passive,
        unreadCount: UInt64((index % 3) + 1),
        totalTokens: UInt64(2_000 + index),
        totalCostUSD: Double(index) * 0.02,
        contextLine: "Updated context \(index)"
      )
      sessions.append(session)
    }
    return sessions
  }

  static func makeSessionListItem(
    id: String,
    title: String,
    projectName: String,
    branch: String,
    status: ServerSessionStatus,
    workStatus: ServerWorkStatus,
    codexIntegrationMode: ServerCodexIntegrationMode?,
    unreadCount: UInt64,
    totalTokens: UInt64,
    totalCostUSD: Double,
    contextLine: String? = "Initial context"
  ) -> ServerSessionListItem {
    let day = ((abs(id.hashValue) % 9) + 1)
    let hour = abs(id.hashValue) % 20
    let iso = String(format: "2026-03-%02dT%02d:00:00Z", day, hour)

    return ServerSessionListItem(
      id: id,
      provider: .codex,
      projectPath: "/tmp/\(projectName.lowercased().replacingOccurrences(of: " ", with: "-"))",
      projectName: projectName,
      gitBranch: branch,
      model: "gpt-5.4",
      status: status,
      workStatus: workStatus,
      codexIntegrationMode: codexIntegrationMode,
      claudeIntegrationMode: nil,
      startedAt: iso,
      lastActivityAt: iso,
      unreadCount: unreadCount,
      hasTurnDiff: false,
      pendingToolName: nil,
      repositoryRoot: "/tmp/\(projectName.lowercased().replacingOccurrences(of: " ", with: "-"))",
      isWorktree: false,
      worktreeId: nil,
      totalTokens: totalTokens,
      totalCostUSD: totalCostUSD,
      displayTitle: title,
      displayTitleSortKey: title.lowercased(),
      displaySearchText: "\(title) \(projectName) \(branch)",
      contextLine: contextLine,
      listStatus: nil,
      effort: nil
    )
  }
}
