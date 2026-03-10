import Foundation

struct LibraryArchiveState: Equatable {
  let providerScopedSessions: [Session]
  let endpointFacets: [LibraryEndpointFacet]
  let endpointScopedSessions: [Session]
  let filteredSessions: [Session]
  let summary: LibraryArchiveSummary
  let selectedEndpointFacet: LibraryEndpointFacet?
  let scopeDescription: String
  let projectGroups: [LibraryProjectGroup]
}

struct LibraryProjectGroup: Identifiable, Equatable {
  let path: String
  let name: String
  let liveSessions: [Session]
  let archivedSessions: [Session]
  let activeSessionCount: Int
  let totalCost: Double
  let totalTokens: Int
  let endpointFacets: [LibraryEndpointFacet]

  var id: String { path }

  var totalSessionCount: Int {
    liveSessions.count + archivedSessions.count
  }

  var cachedActiveSessionCount: Int {
    max(activeSessionCount - liveSessions.count, 0)
  }

  var latestActivity: Date {
    let allSessions = liveSessions + archivedSessions
    return allSessions.compactMap { $0.lastActivityAt ?? $0.startedAt }.max() ?? .distantPast
  }
}

struct LibraryEndpointFacet: Identifiable, Hashable {
  let endpointId: UUID
  let name: String
  let sessionCount: Int
  let isConnected: Bool

  var id: UUID { endpointId }
}

struct LibraryArchiveSummary: Equatable {
  let projectCount: Int
  let sessionCount: Int
  let liveCount: Int
  let endpointCount: Int
}

enum LibraryArchivePlanner {
  static func state(
    sessions: [Session],
    searchText: String,
    providerFilter: ActiveSessionProviderFilter,
    selectedEndpointId: UUID?,
    sort: ActiveSessionSort
  ) -> LibraryArchiveState {
    let providerScopedSessions = providerScopedSessions(
      sessions: sessions,
      providerFilter: providerFilter
    )
    let endpointFacets = endpointFacets(from: providerScopedSessions)
    let selectedEndpointFacet = selectedEndpointFacet(
      endpointId: selectedEndpointId,
      endpointFacets: endpointFacets
    )
    let endpointScopedSessions = endpointScopedSessions(
      sessions: providerScopedSessions,
      selectedEndpointFacet: selectedEndpointFacet
    )
    let filteredSessions = filteredSessions(
      sessions: endpointScopedSessions,
      query: searchText
    )
    let summary = summary(for: filteredSessions)

    return LibraryArchiveState(
      providerScopedSessions: providerScopedSessions,
      endpointFacets: endpointFacets,
      endpointScopedSessions: endpointScopedSessions,
      filteredSessions: filteredSessions,
      summary: summary,
      selectedEndpointFacet: selectedEndpointFacet,
      scopeDescription: scopeDescription(
        summary: summary,
        providerFilter: providerFilter,
        selectedEndpointFacet: selectedEndpointFacet
      ),
      projectGroups: projectGroups(
        sessions: filteredSessions,
        sort: sort
      )
    )
  }

  static func providerScopedSessions(
    sessions: [Session],
    providerFilter: ActiveSessionProviderFilter
  ) -> [Session] {
    switch providerFilter {
      case .all:
        sessions
      case .claude:
        sessions.filter { $0.provider == .claude }
      case .codex:
        sessions.filter { $0.provider == .codex }
    }
  }

  static func endpointFacets(from sessions: [Session]) -> [LibraryEndpointFacet] {
    let grouped = Dictionary(grouping: sessions) { $0.endpointId }

    return grouped
      .compactMap { entry -> LibraryEndpointFacet? in
        guard let endpointId = entry.key else { return nil }
        let endpointSessions = entry.value
        let sortedSessions = endpointSessions.sorted { activityDate(for: $0) > activityDate(for: $1) }
        let endpointName = sortedSessions.compactMap(\.endpointName).first ?? "Endpoint"
        let isConnected = sortedSessions.contains { session in
          guard let status = session.endpointConnectionStatus else { return false }
          if case .connected = status { return true }
          return false
        }

        return LibraryEndpointFacet(
          endpointId: endpointId,
          name: endpointName,
          sessionCount: endpointSessions.count,
          isConnected: isConnected
        )
      }
      .sorted { lhs, rhs in
        let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if comparison != .orderedSame {
          return comparison == .orderedAscending
        }
        return lhs.endpointId.uuidString < rhs.endpointId.uuidString
      }
  }

  static func selectedEndpointFacet(
    endpointId: UUID?,
    endpointFacets: [LibraryEndpointFacet]
  ) -> LibraryEndpointFacet? {
    guard let endpointId else { return nil }
    return endpointFacets.first(where: { $0.endpointId == endpointId })
  }

  static func endpointScopedSessions(
    sessions: [Session],
    selectedEndpointFacet: LibraryEndpointFacet?
  ) -> [Session] {
    guard let selectedEndpointFacet else { return sessions }
    return sessions.filter { $0.endpointId == selectedEndpointFacet.endpointId }
  }

  static func filteredSessions(
    sessions: [Session],
    query: String
  ) -> [Session] {
    guard !query.isEmpty else { return sessions }

    let loweredQuery = query.lowercased()
    return sessions.filter { session in
      let fields = [
        session.displayName,
        session.projectName,
        session.projectPath,
        session.firstPrompt,
        session.lastMessage,
        session.branch,
        session.endpointName,
        session.model,
      ]
      .compactMap { $0?.lowercased() }

      return fields.contains { $0.contains(loweredQuery) }
    }
  }

  static func summary(for sessions: [Session]) -> LibraryArchiveSummary {
    LibraryArchiveSummary(
      projectCount: Set(sessions.map(\.groupingPath)).count,
      sessionCount: sessions.count,
      liveCount: sessions.filter(isLiveSession(_:)).count,
      endpointCount: Set(sessions.compactMap(\.endpointId)).count
    )
  }

  static func scopeDescription(
    summary: LibraryArchiveSummary,
    providerFilter: ActiveSessionProviderFilter,
    selectedEndpointFacet: LibraryEndpointFacet?
  ) -> String {
    var segments: [String] = []

    if let selectedEndpointFacet {
      segments.append(selectedEndpointFacet.name)
    } else if summary.endpointCount > 1 {
      segments.append("\(summary.endpointCount) servers")
    } else {
      segments.append("all servers")
    }

    if providerFilter != .all {
      segments.append(providerFilter.label)
    } else {
      segments.append("all providers")
    }

    segments.append("\(summary.sessionCount) sessions")
    return segments.joined(separator: " • ")
  }

  static func projectGroups(
    sessions: [Session],
    sort: ActiveSessionSort
  ) -> [LibraryProjectGroup] {
    let grouped = Dictionary(grouping: sessions) { $0.groupingPath }

    return grouped.map { path, projectSessions in
      let name = projectSessions.first?.projectName
        ?? path.components(separatedBy: "/").last
        ?? "Unknown"

      let liveSessions = projectSessions
        .filter(isLiveSession(_:))
        .sorted { activityDate(for: $0) > activityDate(for: $1) }

      let archivedSessions = projectSessions
        .filter { !isLiveSession($0) }
        .sorted { lhs, rhs in
          if lhs.isActive != rhs.isActive {
            return lhs.isActive && !rhs.isActive
          }
          return activityDate(for: lhs) > activityDate(for: rhs)
        }

      return LibraryProjectGroup(
        path: path,
        name: name,
        liveSessions: liveSessions,
        archivedSessions: archivedSessions,
        activeSessionCount: projectSessions.filter(\.isActive).count,
        totalCost: projectSessions.reduce(0.0) { $0 + $1.totalCostUSD },
        totalTokens: projectSessions.reduce(0) { $0 + $1.totalTokens },
        endpointFacets: endpointFacets(from: projectSessions)
      )
    }
    .sorted { lhs, rhs in
      switch sort {
        case .recent:
          return lhs.latestActivity > rhs.latestActivity
        case .name:
          return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        case .cost:
          if lhs.totalCost != rhs.totalCost { return lhs.totalCost > rhs.totalCost }
          return lhs.latestActivity > rhs.latestActivity
        case .tokens:
          if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens > rhs.totalTokens }
          return lhs.latestActivity > rhs.latestActivity
        case .status:
          if lhs.liveSessions.count != rhs.liveSessions.count {
            return lhs.liveSessions.count > rhs.liveSessions.count
          }
          if lhs.cachedActiveSessionCount != rhs.cachedActiveSessionCount {
            return lhs.cachedActiveSessionCount > rhs.cachedActiveSessionCount
          }
          return lhs.latestActivity > rhs.latestActivity
      }
    }
  }

  static func activityDate(for session: Session) -> Date {
    session.lastActivityAt ?? session.endedAt ?? session.startedAt ?? .distantPast
  }

  static func isLiveSession(_ session: Session) -> Bool {
    session.isActive && session.hasLiveEndpointConnection
  }
}
