import SwiftUI

struct ConversationGroupKey: Hashable {
  let path: String
  let endpointId: UUID
}

struct ConversationProjectGroup: Identifiable {
  let path: String
  let endpointId: UUID
  let endpointName: String?
  let name: String
  let conversations: [DashboardConversationRecord]
  let sortedConversations: [DashboardConversationRecord]
  let attentionCount: Int
  let workingCount: Int
  let readyCount: Int
  let lastActivityAt: Date?

  var id: String {
    "\(path)::\(endpointId.uuidString)"
  }

  /// The most urgent status color in this group — used for the section signal dot
  var signalColor: Color {
    if attentionCount > 0 { return .statusPermission }
    if workingCount > 0 { return .statusWorking }
    return .statusReply
  }
}

enum ConversationProjectGroupSortMode {
  case dashboard
  case sidebar
}

enum ConversationProjectGroupBuilder {
  /// Build grouped projects from conversations.
  /// - Parameter customOrder: Optional array of project paths. When non-empty, groups are sorted
  ///   to match this order. New/unknown projects append alphabetically after the ordered ones.
  static func build(
    from conversations: [DashboardConversationRecord],
    customOrder: [String] = [],
    sortMode: ConversationProjectGroupSortMode = .dashboard
  ) -> [ConversationProjectGroup] {
    let groups = Dictionary(grouping: conversations) { conv in
      ConversationGroupKey(path: conv.groupingPath, endpointId: conv.sessionRef.endpointId)
    }

    let unsorted = groups.compactMap { key, conversations -> ConversationProjectGroup? in
      guard let first = conversations.first else { return nil }
      let sortedConversations = sortConversations(conversations, mode: sortMode)
      return ConversationProjectGroup(
        path: key.path,
        endpointId: key.endpointId,
        endpointName: first.endpointName,
        name: first.displayProjectName,
        conversations: conversations,
        sortedConversations: sortedConversations,
        attentionCount: conversations.filter(\.displayStatus.needsAttention).count,
        workingCount: conversations.filter { $0.displayStatus == .working }.count,
        readyCount: conversations.filter { $0.displayStatus == .reply }.count,
        lastActivityAt: conversations.compactMap { $0.lastActivityAt ?? $0.startedAt }.max()
      )
    }

    if customOrder.isEmpty {
      return unsorted.sorted(by: alphabeticalSort)
    }

    // Custom order: known paths sort by position, unknown paths append alphabetically
    let orderIndex = Dictionary(uniqueKeysWithValues: customOrder.enumerated().map { ($1, $0) })

    let ordered = unsorted.filter { orderIndex[$0.path] != nil }
      .sorted { (orderIndex[$0.path] ?? 0) < (orderIndex[$1.path] ?? 0) }

    let unordered = unsorted.filter { orderIndex[$0.path] == nil }
      .sorted(by: alphabeticalSort)

    return ordered + unordered
  }

  private nonisolated static func alphabeticalSort(
    lhs: ConversationProjectGroup,
    rhs: ConversationProjectGroup
  ) -> Bool {
    let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
    if nameOrder != .orderedSame {
      return nameOrder == .orderedAscending
    }
    return lhs.path < rhs.path
  }

  private static func sortConversations(
    _ conversations: [DashboardConversationRecord],
    mode: ConversationProjectGroupSortMode
  ) -> [DashboardConversationRecord] {
    Array(conversations.enumerated())
      .sorted { lhs, rhs in
        switch mode {
          case .dashboard:
            let lhsBucket = sortBucket(for: lhs.element.displayStatus)
            let rhsBucket = sortBucket(for: rhs.element.displayStatus)
            if lhsBucket != rhsBucket {
              return lhsBucket < rhsBucket
            }

            let lhsDate = lhs.element.startedAt ?? .distantPast
            let rhsDate = rhs.element.startedAt ?? .distantPast
            if lhsDate != rhsDate {
              return lhsDate > rhsDate
            }

          case .sidebar:
            let lhsIsWorking = lhs.element.displayStatus == .working
            let rhsIsWorking = rhs.element.displayStatus == .working
            if lhsIsWorking != rhsIsWorking {
              return lhsIsWorking && !rhsIsWorking
            }

            if !lhsIsWorking {
              let lhsDate = lhs.element.lastActivityAt ?? lhs.element.startedAt ?? .distantPast
              let rhsDate = rhs.element.lastActivityAt ?? rhs.element.startedAt ?? .distantPast
              if lhsDate != rhsDate {
                return lhsDate > rhsDate
              }
            }
        }

        return lhs.offset < rhs.offset
      }
      .map(\.element)
  }

  private static func sortBucket(for status: SessionDisplayStatus) -> Int {
    status == .working ? 0 : 1
  }
}
