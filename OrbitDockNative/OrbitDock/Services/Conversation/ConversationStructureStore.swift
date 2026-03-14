import Foundation

struct ConversationStructureSnapshot: Sendable, Equatable {
  let session: ScopedSessionID
  let rows: [ConversationRowRecord]
  let oldestLoadedSequence: UInt64?
  let newestLoadedSequence: UInt64?
  let hasMoreHistoryBefore: Bool

  init(
    session: ScopedSessionID,
    rows: [ConversationRowRecord] = [],
    oldestLoadedSequence: UInt64? = nil,
    newestLoadedSequence: UInt64? = nil,
    hasMoreHistoryBefore: Bool = false
  ) {
    self.session = session
    self.rows = rows
    self.oldestLoadedSequence = oldestLoadedSequence
    self.newestLoadedSequence = newestLoadedSequence
    self.hasMoreHistoryBefore = hasMoreHistoryBefore
  }
}

enum ConversationStructureEvent: Sendable, Equatable {
  case bootstrap(rows: [ConversationRowRecord], oldestLoadedSequence: UInt64?, newestLoadedSequence: UInt64?, hasMoreHistoryBefore: Bool)
  case prepend(rows: [ConversationRowRecord], oldestLoadedSequence: UInt64?, hasMoreHistoryBefore: Bool)
  case append(row: ConversationRowRecord)
  case replace(rowID: String, row: ConversationRowRecord)
  case remove(rowID: String)
  case clear
}

struct ConversationStructureStore: Sendable, Equatable {
  private(set) var snapshot: ConversationStructureSnapshot

  init(session: ScopedSessionID) {
    snapshot = ConversationStructureSnapshot(session: session)
  }

  mutating func apply(_ event: ConversationStructureEvent) {
    switch event {
      case let .bootstrap(rows, oldestLoadedSequence, newestLoadedSequence, hasMoreHistoryBefore):
        snapshot = ConversationStructureSnapshot(
          session: snapshot.session,
          rows: dedupe(rows),
          oldestLoadedSequence: oldestLoadedSequence,
          newestLoadedSequence: newestLoadedSequence,
          hasMoreHistoryBefore: hasMoreHistoryBefore
        )

      case let .prepend(rows, oldestLoadedSequence, hasMoreHistoryBefore):
        snapshot = ConversationStructureSnapshot(
          session: snapshot.session,
          rows: dedupe(rows + snapshot.rows),
          oldestLoadedSequence: oldestLoadedSequence ?? snapshot.oldestLoadedSequence,
          newestLoadedSequence: snapshot.newestLoadedSequence,
          hasMoreHistoryBefore: hasMoreHistoryBefore
        )

      case let .append(row):
        snapshot = ConversationStructureSnapshot(
          session: snapshot.session,
          rows: dedupe(snapshot.rows + [row]),
          oldestLoadedSequence: snapshot.oldestLoadedSequence ?? row.sequence,
          newestLoadedSequence: row.sequence ?? snapshot.newestLoadedSequence,
          hasMoreHistoryBefore: snapshot.hasMoreHistoryBefore
        )

      case let .replace(rowID, row):
        let nextRows = snapshot.rows.map { existing in
          existing.id == rowID ? row : existing
        }
        snapshot = ConversationStructureSnapshot(
          session: snapshot.session,
          rows: nextRows,
          oldestLoadedSequence: snapshot.oldestLoadedSequence,
          newestLoadedSequence: snapshot.newestLoadedSequence,
          hasMoreHistoryBefore: snapshot.hasMoreHistoryBefore
        )

      case let .remove(rowID):
        snapshot = ConversationStructureSnapshot(
          session: snapshot.session,
          rows: snapshot.rows.filter { $0.id != rowID },
          oldestLoadedSequence: snapshot.oldestLoadedSequence,
          newestLoadedSequence: snapshot.newestLoadedSequence,
          hasMoreHistoryBefore: snapshot.hasMoreHistoryBefore
        )

      case .clear:
        snapshot = ConversationStructureSnapshot(session: snapshot.session)
    }
  }

  private func dedupe(_ rows: [ConversationRowRecord]) -> [ConversationRowRecord] {
    var seen = Set<String>()
    var ordered: [ConversationRowRecord] = []
    for row in rows {
      guard seen.insert(row.id).inserted else { continue }
      ordered.append(row)
    }
    return ordered
  }
}
