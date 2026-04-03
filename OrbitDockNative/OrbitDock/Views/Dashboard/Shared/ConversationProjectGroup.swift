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

  /// Sessions sorted for display with stable ordering to avoid list jumpiness.
  /// "In orbit" sessions stay pinned to the top, but preserve stable ordering
  /// within that bucket.
  var sortedConversations: [DashboardConversationRecord] {
    conversations.sorted { lhs, rhs in
      let lhsBucket = Self.sortBucket(for: lhs.displayStatus)
      let rhsBucket = Self.sortBucket(for: rhs.displayStatus)
      if lhsBucket != rhsBucket {
        return lhsBucket < rhsBucket
      }

      let lhsDate = lhs.startedAt ?? .distantPast
      let rhsDate = rhs.startedAt ?? .distantPast
      if lhsDate != rhsDate {
        return lhsDate > rhsDate
      }
      return lhs.id < rhs.id
    }
  }

  private static func sortBucket(for status: SessionDisplayStatus) -> Int {
    status == .working ? 0 : 1
  }
}

enum ConversationProjectGroupBuilder {
  /// Build grouped projects from conversations.
  /// - Parameter customOrder: Optional array of project paths. When non-empty, groups are sorted
  ///   to match this order. New/unknown projects append alphabetically after the ordered ones.
  static func build(
    from conversations: [DashboardConversationRecord],
    customOrder: [String] = []
  ) -> [ConversationProjectGroup] {
    let groups = Dictionary(grouping: conversations) { conv in
      ConversationGroupKey(path: conv.groupingPath, endpointId: conv.sessionRef.endpointId)
    }

    let unsorted = groups.compactMap { key, conversations -> ConversationProjectGroup? in
      guard let first = conversations.first else { return nil }
      return ConversationProjectGroup(
        path: key.path,
        endpointId: key.endpointId,
        endpointName: first.endpointName,
        name: first.displayProjectName,
        conversations: conversations,
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
}
