import Foundation
import Observation

@MainActor
@Observable
final class ConversationTimelineViewModel {
  private let fetchedRowContentLimit = 24
  private var currentSessionId: String?
  private var currentViewMode: ChatViewMode = .focused
  private var projection = TimelineDataSource.Projection.make(entries: [], viewMode: .focused)
  private var lastStructureRevision = 0
  private var lastContentRevision = 0

  private var expandedRowIDs: Set<String> = []
  private var fetchedRowContent: [String: ServerRowContent] = [:]
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
    fetchedRowContentOrder.removeAll()
    rowContentFetchInFlight.removeAll()
    lastStructureRevision = 0
    lastContentRevision = 0
  }

  private func cacheRowContent(_ content: ServerRowContent, for rowId: String) {
    fetchedRowContent[rowId] = content
    fetchedRowContentOrder.removeAll { $0 == rowId }
    fetchedRowContentOrder.append(rowId)
    while fetchedRowContentOrder.count > fetchedRowContentLimit {
      let evicted = fetchedRowContentOrder.removeFirst()
      fetchedRowContent.removeValue(forKey: evicted)
    }
  }

  private func pruneCaches(validRowIDs: Set<String>) {
    expandedRowIDs = expandedRowIDs.filter { validRowIDs.contains($0) }
    fetchedRowContent = fetchedRowContent.filter { validRowIDs.contains($0.key) }
    fetchedRowContentOrder = fetchedRowContentOrder.filter { validRowIDs.contains($0) }
    rowContentFetchInFlight = rowContentFetchInFlight.filter { validRowIDs.contains($0) }
  }
}
