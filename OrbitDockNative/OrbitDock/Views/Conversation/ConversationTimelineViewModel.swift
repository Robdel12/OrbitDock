import Foundation
import Observation

@MainActor
@Observable
final class ConversationTimelineViewModel {
  private let fetchedRowContentLimit = 24
  #if os(iOS)
    private let fetchedRowContentTotalCostLimit = 1_500_000
  #else
    private let fetchedRowContentTotalCostLimit = 4_000_000
  #endif
  private var currentSessionId: String?
  private var currentViewMode: ChatViewMode = .focused
  private var projection = TimelineDataSource.Projection.make(entries: [], viewMode: .focused)
  private var lastStructureRevision = 0
  private var lastContentRevision = 0

  private var expandedRowIDs: Set<String> = []
  private var fetchedRowContent: [String: ServerRowContent] = [:]
  private var fetchedRowContentCostByRowID: [String: Int] = [:]
  private var fetchedRowContentTotalCost = 0
  private var fetchedRowContentOrder: [String] = []
  private var rowContentFetchInFlight: Set<String> = []

  var displayedEntryCount: Int {
    projection.count
  }

  func renderedEntries(limit: Int) -> ArraySlice<ServerConversationRowEntry> {
    projection.suffix(limit)
  }

  func displayAnchorID(for rowId: String) -> String? {
    projection.displayAnchorID(for: rowId)
  }

  func renderWindowRequiredToReveal(rowId: String) -> Int? {
    projection.suffixCountRequiredToRender(rowID: rowId)
  }

  func bind(sessionId: String?) {
    guard currentSessionId != sessionId else { return }
    currentSessionId = sessionId
    clearSession()
  }

  func apply(
    presentation: ConversationTimelinePresentation,
    viewMode: ChatViewMode
  ) {
    let shouldRebuild =
      viewMode != currentViewMode
        || presentation.structureRevision != lastStructureRevision
        || (projection.count == 0) != presentation.entries.isEmpty

    currentViewMode = viewMode

    if shouldRebuild {
      projection = TimelineDataSource.Projection.make(entries: presentation.entries, viewMode: viewMode)
    } else if presentation.contentRevision != lastContentRevision {
      projection.applyContentUpdates(changedEntries: presentation.changedEntries)
    }

    pruneCaches(validRowIDs: Set(presentation.entries.map(\.id)))

    lastStructureRevision = presentation.structureRevision
    lastContentRevision = presentation.contentRevision
  }

  func isExpanded(_ id: String) -> Bool {
    expandedRowIDs.contains(id)
  }

  func content(for rowId: String) -> ServerRowContent? {
    fetchedRowContent[rowId]
  }

  func isFetching(_ rowId: String) -> Bool {
    rowContentFetchInFlight.contains(rowId)
  }

  @discardableResult
  func toggleExpanded(_ id: String) -> Bool {
    if expandedRowIDs.contains(id) {
      expandedRowIDs.remove(id)
      return false
    } else {
      expandedRowIDs.insert(id)
      return true
    }
  }

  func fetchContentIfNeeded(
    rowId: String,
    sessionId: String,
    clients: ServerClients
  ) {
    guard fetchedRowContent[rowId] == nil, !rowContentFetchInFlight.contains(rowId) else { return }
    rowContentFetchInFlight.insert(rowId)
    Task {
      do {
        let content = try await clients.conversation.fetchRowContent(
          sessionId: sessionId,
          rowId: rowId
        )
        cacheRowContent(content, for: rowId)
      } catch {}
      rowContentFetchInFlight.remove(rowId)
    }
  }

  func clearSession() {
    projection = TimelineDataSource.Projection.make(entries: [], viewMode: currentViewMode)
    expandedRowIDs.removeAll()
    fetchedRowContent.removeAll()
    fetchedRowContentCostByRowID.removeAll()
    fetchedRowContentTotalCost = 0
    fetchedRowContentOrder.removeAll()
    rowContentFetchInFlight.removeAll()
    lastStructureRevision = 0
    lastContentRevision = 0
  }

  private func cacheRowContent(_ content: ServerRowContent, for rowId: String) {
    let estimatedCost = estimatedCost(for: content)
    if let existingCost = fetchedRowContentCostByRowID[rowId] {
      fetchedRowContentTotalCost -= existingCost
    }
    fetchedRowContent[rowId] = content
    fetchedRowContentCostByRowID[rowId] = estimatedCost
    fetchedRowContentTotalCost += estimatedCost
    fetchedRowContentOrder.removeAll { $0 == rowId }
    fetchedRowContentOrder.append(rowId)

    while fetchedRowContentOrder.count > fetchedRowContentLimit
      || fetchedRowContentTotalCost > fetchedRowContentTotalCostLimit
    {
      if fetchedRowContentOrder.count == 1 {
        break
      }
      let evicted = fetchedRowContentOrder.removeFirst()
      removeCachedContent(for: evicted)
    }
  }

  private func pruneCaches(validRowIDs: Set<String>) {
    expandedRowIDs = expandedRowIDs.filter { validRowIDs.contains($0) }
    let staleContentRowIDs = Set(fetchedRowContent.keys).subtracting(validRowIDs)
    for rowId in staleContentRowIDs {
      removeCachedContent(for: rowId)
    }
    fetchedRowContentOrder = fetchedRowContentOrder.filter { validRowIDs.contains($0) }
    rowContentFetchInFlight = rowContentFetchInFlight.filter { validRowIDs.contains($0) }
  }

  private func removeCachedContent(for rowId: String) {
    fetchedRowContent.removeValue(forKey: rowId)
    if let removedCost = fetchedRowContentCostByRowID.removeValue(forKey: rowId) {
      fetchedRowContentTotalCost = max(fetchedRowContentTotalCost - removedCost, 0)
    }
    fetchedRowContentOrder.removeAll { $0 == rowId }
  }

  private func estimatedCost(for content: ServerRowContent) -> Int {
    var total = 256
    total += content.inputDisplay?.utf8.count ?? 0
    total += content.outputDisplay?.utf8.count ?? 0
    total += content.language?.utf8.count ?? 0
    if let diffDisplay = content.diffDisplay {
      for line in diffDisplay {
        total += line.content.utf8.count + 24
      }
    }
    return max(total, 1)
  }
}
