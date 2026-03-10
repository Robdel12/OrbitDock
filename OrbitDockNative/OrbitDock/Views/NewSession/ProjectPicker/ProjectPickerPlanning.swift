import Foundation

struct ProjectPickerRecentWorktreeProject: Identifiable {
  let project: ServerRecentProject
  let repoPath: String
  let branchPath: String

  var id: String {
    project.id
  }
}

struct GroupedRecentProject: Identifiable, Equatable {
  let repoPath: String
  let repoProject: ServerRecentProject?
  let worktrees: [ProjectPickerRecentWorktreeProject]
  let totalSessionCount: UInt32
  let lastActive: String?

  var id: String {
    repoPath
  }

  static func == (lhs: GroupedRecentProject, rhs: GroupedRecentProject) -> Bool {
    lhs.repoPath == rhs.repoPath
      && lhs.repoProject?.id == rhs.repoProject?.id
      && lhs.repoProject?.path == rhs.repoProject?.path
      && lhs.repoProject?.sessionCount == rhs.repoProject?.sessionCount
      && lhs.repoProject?.lastActive == rhs.repoProject?.lastActive
      && lhs.worktrees.elementsEqual(rhs.worktrees, by: {
        $0.project.id == $1.project.id
          && $0.project.path == $1.project.path
          && $0.project.sessionCount == $1.project.sessionCount
          && $0.project.lastActive == $1.project.lastActive
          && $0.repoPath == $1.repoPath
          && $0.branchPath == $1.branchPath
      })
      && lhs.totalSessionCount == rhs.totalSessionCount
      && lhs.lastActive == rhs.lastActive
  }
}

struct ProjectPickerBrowseProjection: Equatable {
  let currentBrowsePath: String
  let browseHistory: [String]
  let directoryEntries: [ServerDirectoryEntry]

  static func == (lhs: ProjectPickerBrowseProjection, rhs: ProjectPickerBrowseProjection) -> Bool {
    lhs.currentBrowsePath == rhs.currentBrowsePath
      && lhs.browseHistory == rhs.browseHistory
      && lhs.directoryEntries.elementsEqual(rhs.directoryEntries, by: {
        $0.name == $1.name && $0.isDir == $1.isDir && $0.isGit == $1.isGit
      })
  }
}

enum ProjectPickerPlanner {
  nonisolated static func displayPath(_ path: String) -> String {
    if path.hasPrefix("/Users/") {
      let parts = path.split(separator: "/", maxSplits: 3)
      if parts.count >= 2 {
        return "~/" + (parts.count > 2 ? String(parts[2...].joined(separator: "/")) : "")
      }
    }
    return path.isEmpty ? "~" : path
  }

  nonisolated static func sessionCountLabel(_ count: UInt32) -> String {
    "\(count) session\(count == 1 ? "" : "s")"
  }

  nonisolated static func worktreeRelativePath(_ worktree: ProjectPickerRecentWorktreeProject) -> String {
    let repoName = URL(fileURLWithPath: worktree.repoPath).lastPathComponent
    return "\(repoName)/.orbitdock-worktrees/\(worktree.branchPath)"
  }

  nonisolated static func groupedRecentProjects(from projects: [ServerRecentProject]) -> [GroupedRecentProject] {
    struct Accumulator {
      var repoProject: ServerRecentProject?
      var worktrees: [ProjectPickerRecentWorktreeProject] = []
      var totalSessionCount: UInt32 = 0
      var lastActive: String?

      mutating func include(_ project: ServerRecentProject) {
        totalSessionCount += project.sessionCount
        if let active = project.lastActive,
           lastActive == nil || active > lastActive!
        {
          lastActive = active
        }
      }
    }

    var grouped: [String: Accumulator] = [:]

    for project in projects {
      if let parsed = parseOrbitDockWorktreePath(project.path) {
        var bucket = grouped[parsed.repoPath] ?? Accumulator()
        bucket.worktrees.append(
          ProjectPickerRecentWorktreeProject(
            project: project,
            repoPath: parsed.repoPath,
            branchPath: parsed.branchPath
          )
        )
        bucket.include(project)
        grouped[parsed.repoPath] = bucket
        continue
      }

      var bucket = grouped[project.path] ?? Accumulator()
      bucket.repoProject = project
      bucket.include(project)
      grouped[project.path] = bucket
    }

    return grouped.map { repoPath, bucket in
      let sortedWorktrees = bucket.worktrees.sorted {
        if $0.project.lastActive == $1.project.lastActive {
          return $0.branchPath < $1.branchPath
        }
        return ($0.project.lastActive ?? "") > ($1.project.lastActive ?? "")
      }

      return GroupedRecentProject(
        repoPath: repoPath,
        repoProject: bucket.repoProject,
        worktrees: sortedWorktrees,
        totalSessionCount: bucket.totalSessionCount,
        lastActive: bucket.lastActive
      )
    }
    .sorted {
      if $0.lastActive == $1.lastActive {
        return $0.repoPath < $1.repoPath
      }
      return ($0.lastActive ?? "") > ($1.lastActive ?? "")
    }
  }

  nonisolated static func parseOrbitDockWorktreePath(_ path: String) -> (repoPath: String, branchPath: String)? {
    let marker = "/.orbitdock-worktrees/"
    guard let markerRange = path.range(of: marker) else {
      return nil
    }

    let repoPath = String(path[..<markerRange.lowerBound])
    let branchPath = String(path[markerRange.upperBound...])
    guard !repoPath.isEmpty, !branchPath.isEmpty else {
      return nil
    }
    return (repoPath, branchPath)
  }

  nonisolated static func canNavigateBack(_ browseHistory: [String]) -> Bool {
    !browseHistory.isEmpty
  }

  nonisolated static func childPath(entryName: String, currentBrowsePath: String) -> String {
    currentBrowsePath.isEmpty ? entryName : "\(currentBrowsePath)/\(entryName)"
  }

  nonisolated static func applyBrowseResponse(
    requestedPath: String?,
    currentBrowsePath: String,
    browseHistory: [String],
    browsedPath: String,
    entries: [ServerDirectoryEntry]
  ) -> ProjectPickerBrowseProjection {
    var nextHistory = browseHistory
    if let requestedPath, !requestedPath.isEmpty {
      nextHistory.append(currentBrowsePath)
    }

    return ProjectPickerBrowseProjection(
      currentBrowsePath: browsedPath,
      browseHistory: nextHistory,
      directoryEntries: entries
    )
  }

  nonisolated static func applyNavigateBackResponse(
    browseHistory: [String],
    browsedPath: String,
    entries: [ServerDirectoryEntry]
  ) -> ProjectPickerBrowseProjection? {
    guard !browseHistory.isEmpty else { return nil }

    var nextHistory = browseHistory
    _ = nextHistory.popLast()
    return ProjectPickerBrowseProjection(
      currentBrowsePath: browsedPath,
      browseHistory: nextHistory,
      directoryEntries: entries
    )
  }

  nonisolated static func resetBrowseProjection() -> ProjectPickerBrowseProjection {
    ProjectPickerBrowseProjection(
      currentBrowsePath: "",
      browseHistory: [],
      directoryEntries: []
    )
  }

  nonisolated static func shouldApplyResponse(
    requestId: UUID,
    activeRequestId: UUID,
    requestEndpointId: UUID,
    activeEndpointId: UUID?
  ) -> Bool {
    requestId == activeRequestId && activeEndpointId == requestEndpointId
  }
}
