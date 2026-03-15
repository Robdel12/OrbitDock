//
//  TimelineRowStateStore.swift
//  OrbitDock
//
//  Centralizes per-row mutable state: expansion, fetched content, loading state.
//  Cells read from this store and are pure functions of their inputs.
//  State survives cell reuse — the store outlives any individual cell.
//

import Foundation

@MainActor
final class TimelineRowStateStore {
  // MARK: - Expansion

  private(set) var expandedIDs: Set<String> = []

  @discardableResult
  func toggleExpanded(_ id: String) -> Bool {
    if expandedIDs.contains(id) {
      expandedIDs.remove(id)
      return false
    } else {
      expandedIDs.insert(id)
      return true
    }
  }

  func isExpanded(_ id: String) -> Bool {
    expandedIDs.contains(id)
  }

  // MARK: - Fetched Content

  private(set) var fetchedContent: [String: ServerRowContent] = [:]
  private var fetchInFlight: Set<String> = []

  func content(for rowId: String) -> ServerRowContent? {
    fetchedContent[rowId]
  }

  var isFetchingContent: Set<String> { fetchInFlight }

  func isFetching(_ rowId: String) -> Bool {
    fetchInFlight.contains(rowId)
  }

  /// Fetch expanded content if not already cached or in-flight.
  /// Calls `onFetched` on completion so the controller can invalidate heights.
  func fetchContentIfNeeded(
    rowId: String, sessionId: String,
    clients: ServerClients, onFetched: @escaping () -> Void
  ) {
    guard fetchedContent[rowId] == nil, !fetchInFlight.contains(rowId) else { return }
    fetchInFlight.insert(rowId)
    Task {
      do {
        let content = try await clients.conversation.fetchRowContent(
          sessionId: sessionId, rowId: rowId
        )
        fetchedContent[rowId] = content
      } catch {}
      fetchInFlight.remove(rowId)
      onFetched()
    }
  }

  // MARK: - Height Cache

  private var heightCache: [String: CGFloat] = [:]

  func cachedHeight(_ rowId: String) -> CGFloat? {
    heightCache[rowId]
  }

  func cacheHeight(_ rowId: String, _ height: CGFloat) {
    heightCache[rowId] = height
  }

  func invalidateHeight(_ rowId: String) {
    heightCache.removeValue(forKey: rowId)
  }

  func invalidateAllHeights() {
    heightCache.removeAll()
  }

  // MARK: - Session Lifecycle

  func clearSession() {
    expandedIDs.removeAll()
    fetchedContent.removeAll()
    fetchInFlight.removeAll()
    heightCache.removeAll()
  }
}
