import Observation
import SwiftUI

@MainActor
@Observable
final class ConversationViewModel {
  var hasShownContent = false
  var currentSessionId: String?
  var currentSessionStore = SessionStore.preview()
  var currentViewMode: ChatViewMode = .focused
  var hasTimeline = false
  var timelineViewModel = ConversationTimelineViewModel()
  var latestAppendEvent: ConversationLatestAppendEvent?
  var loadState: ConversationLoadState = .empty
  var forkOrigin: ConversationForkOriginPresentation?

  // Owned row state — no SessionObservable dependency.
  @ObservationIgnored private var rowEntries: [ServerConversationRowEntry] = []
  @ObservationIgnored private var structureRevision: Int = 0
  @ObservationIgnored private var contentRevision: Int = 0
  @ObservationIgnored private var lastNewestSequence: UInt64 = 0
  @ObservationIgnored private var conversationLoaded = false
  @ObservationIgnored private var hasMoreBefore = false
  @ObservationIgnored private var totalRowCount: UInt64 = 0
  @ObservationIgnored private var isLoadingOlder = false
  @ObservationIgnored private var isRefreshing = false
  @ObservationIgnored private var refreshQueued = false
  @ObservationIgnored private var bufferedRowDeltas: [SessionStore.ConversationRowDelta] = []

  private let pageSize = 50

  func bind(sessionId: String?, sessionStore: SessionStore, viewMode: ChatViewMode) {
    let didChange = currentSessionId != sessionId || currentSessionStore !== sessionStore
    currentSessionId = sessionId
    currentSessionStore = sessionStore
    currentViewMode = viewMode
    timelineViewModel.bind(sessionId: sessionId)

    if didChange {
      rowEntries = []
      structureRevision = 0
      contentRevision = 0
      lastNewestSequence = 0
      conversationLoaded = false
      hasMoreBefore = false
      totalRowCount = 0
      isLoadingOlder = false
      forkOrigin = nil
      bufferedRowDeltas.removeAll()
      rebuildPresentation(changedEntries: [])
    }
  }

  /// Refresh the authoritative conversation bootstrap from HTTP.
  /// The row-delta stream stays alive independently so transient transport
  /// failures do not strand the screen.
  func refresh() async {
    guard let sessionId = currentSessionId, !sessionId.isEmpty else { return }
    if isRefreshing {
      refreshQueued = true
      return
    }

    isRefreshing = true
    refreshQueued = false
    defer {
      isRefreshing = false
      if refreshQueued {
        refreshQueued = false
        Task { await refresh() }
      }
    }

    let store = currentSessionStore

    do {
      let bootstrap = try await store.clients.conversation.fetchConversationBootstrap(
        sessionId,
        limit: pageSize
      )
      guard currentSessionId == sessionId, currentSessionStore === store else { return }
      applyBootstrap(bootstrap, store: store)
      drainBufferedRowDeltas()
    } catch {
      netLog(.error, cat: .store, "Conversation bootstrap failed", sid: sessionId, data: [
        "error": String(describing: error),
      ])
      guard currentSessionId == sessionId else { return }
      if rowEntries.isEmpty {
        conversationLoaded = true
        rebuildPresentation(changedEntries: [])
      }
      drainBufferedRowDeltas()
    }
  }

  func handleConversationRowDelta(_ delta: SessionStore.ConversationRowDelta) {
    if isRefreshing {
      bufferedRowDeltas.append(delta)
      return
    }
    applyDelta(delta)
  }

  func handleTimelineViewModeChange(_ viewMode: ChatViewMode) {
    currentViewMode = viewMode
    rebuildPresentation(changedEntries: [])
  }

  func handleLoadStateChange(_ newState: ConversationLoadState) {
    if newState == .ready {
      hasShownContent = true
    }
  }

  func loadOlderMessages() {
    guard let currentSessionId, hasMoreBefore, !isLoadingOlder else { return }
    guard let oldestSequence = rowEntries.first?.sequence else { return }
    isLoadingOlder = true
    let store = currentSessionStore

    Task {
      defer { isLoadingOlder = false }
      do {
        let page = try await store.clients.conversation.fetchConversationHistory(
          currentSessionId,
          beforeSequence: oldestSequence,
          limit: pageSize
        )
        guard self.currentSessionId == currentSessionId, self.currentSessionStore === store else { return }
        let mergedPage = ConversationHistoryPaging.mergeOlderPage(
          existingRows: rowEntries,
          page: page
        )
        hasMoreBefore = mergedPage.hasMoreBefore
        totalRowCount = mergedPage.totalRowCount
        rowEntries = mergedPage.rows
        structureRevision += 1
        contentRevision += 1
        rebuildPresentation(changedEntries: page.rows)
      } catch {
        netLog(.error, cat: .store, "Load older messages failed", sid: currentSessionId, data: [
          "error": String(describing: error),
        ])
      }
    }
  }

  // MARK: - Private

  private func applyBootstrap(_ bootstrap: ServerConversationBootstrap, store: SessionStore) {
    let mergedBootstrap = ConversationHistoryPaging.mergeBootstrap(
      existingRows: rowEntries,
      existingHasMoreBefore: hasMoreBefore,
      existingTotalRowCount: totalRowCount,
      bootstrapRows: bootstrap.rows,
      bootstrapHasMoreBefore: bootstrap.hasMoreBefore,
      bootstrapTotalRowCount: bootstrap.totalRowCount
    )
    rowEntries = mergedBootstrap.rows
    hasMoreBefore = mergedBootstrap.hasMoreBefore
    totalRowCount = mergedBootstrap.totalRowCount
    conversationLoaded = true
    structureRevision += 1
    contentRevision += 1
    rebuildPresentation(changedEntries: bootstrap.rows)

    if let sourceId = bootstrap.session.forkedFromSessionId {
      forkOrigin = ConversationForkOriginPresentation(
        sourceSessionId: sourceId,
        sourceEndpointId: store.endpointId,
        sourceName: nil
      )
    } else {
      forkOrigin = nil
    }
  }

  private func applyDelta(_ delta: SessionStore.ConversationRowDelta) {
    var changed: [ServerConversationRowEntry] = []
    var structureChanged = false

    // Remove
    if !delta.removedIds.isEmpty {
      let removedSet = Set(delta.removedIds)
      rowEntries.removeAll { removedSet.contains($0.id) }
      structureChanged = true
    }

    // Upsert
    for entry in delta.upserted {
      if let idx = rowEntries.firstIndex(where: { $0.id == entry.id }) {
        rowEntries[idx] = entry
        changed.append(entry)
      } else {
        rowEntries.append(entry)
        changed.append(entry)
        structureChanged = true
      }
    }

    if structureChanged {
      rowEntries.sort { $0.sequence < $1.sequence }
      totalRowCount = max(totalRowCount, UInt64(rowEntries.count))
      structureRevision += 1
    }
    contentRevision += 1
    rebuildPresentation(changedEntries: changed)
  }

  private func drainBufferedRowDeltas() {
    guard !bufferedRowDeltas.isEmpty else { return }
    let deltas = bufferedRowDeltas
    bufferedRowDeltas.removeAll(keepingCapacity: true)
    for delta in deltas {
      applyDelta(delta)
    }
  }

  private func rebuildPresentation(changedEntries: [ServerConversationRowEntry]) {
    let previousNewest = lastNewestSequence
    let timeline = ConversationTimelinePresentation(
      entries: rowEntries,
      contentRevision: contentRevision,
      structureRevision: structureRevision,
      changedEntries: changedEntries
    )

    let nextLoadState: ConversationLoadState = if !rowEntries.isEmpty {
      .ready
    } else if hasShownContent || conversationLoaded {
      .empty
    } else {
      .loading
    }

    let incomingHasTimeline = !rowEntries.isEmpty
    hasTimeline = incomingHasTimeline

    if incomingHasTimeline {
      timelineViewModel.apply(presentation: timeline, viewMode: currentViewMode)

      // Detect appended entries for auto-scroll
      let appendedCount = changedEntries.filter { $0.sequence > previousNewest }.count
      if appendedCount > 0, previousNewest > 0 {
        latestAppendEvent = ConversationLatestAppendEvent(
          count: appendedCount,
          nonce: (latestAppendEvent?.nonce ?? 0) + 1
        )
      }
      lastNewestSequence = rowEntries.last?.sequence ?? 0
    } else {
      timelineViewModel.clearSession()
      lastNewestSequence = 0
    }

    if loadState != nextLoadState {
      loadState = nextLoadState
    }
  }
}

enum ConversationHistoryPaging {
  struct MergeResult {
    let rows: [ServerConversationRowEntry]
    let hasMoreBefore: Bool
    let totalRowCount: UInt64
  }

  static func mergeBootstrap(
    existingRows: [ServerConversationRowEntry],
    existingHasMoreBefore: Bool,
    existingTotalRowCount: UInt64,
    bootstrapRows: [ServerConversationRowEntry],
    bootstrapHasMoreBefore: Bool,
    bootstrapTotalRowCount: UInt64
  ) -> MergeResult {
    let normalizedBootstrapRows = normalizedRows(bootstrapRows)
    guard
      let bootstrapOldestSequence = normalizedBootstrapRows.first?.sequence,
      existingTotalRowCount >= UInt64(existingRows.count),
      bootstrapTotalRowCount >= UInt64(existingRows.count)
    else {
      return MergeResult(
        rows: normalizedBootstrapRows,
        hasMoreBefore: bootstrapHasMoreBefore,
        totalRowCount: bootstrapTotalRowCount
      )
    }

    let preservedOlderRows = existingRows.filter { $0.sequence < bootstrapOldestSequence }
    guard !preservedOlderRows.isEmpty else {
      return MergeResult(
        rows: normalizedBootstrapRows,
        hasMoreBefore: bootstrapHasMoreBefore,
        totalRowCount: bootstrapTotalRowCount
      )
    }

    return MergeResult(
      rows: normalizedRows(preservedOlderRows + normalizedBootstrapRows),
      hasMoreBefore: existingHasMoreBefore,
      totalRowCount: bootstrapTotalRowCount
    )
  }

  static func mergeOlderPage(
    existingRows: [ServerConversationRowEntry],
    page: ServerConversationHistoryPage
  ) -> MergeResult {
    MergeResult(
      rows: normalizedRows(page.rows + existingRows),
      hasMoreBefore: page.hasMoreBefore,
      totalRowCount: page.totalRowCount
    )
  }

  private static func normalizedRows(
    _ rows: [ServerConversationRowEntry]
  ) -> [ServerConversationRowEntry] {
    var entriesByID: [String: ServerConversationRowEntry] = [:]
    for row in rows {
      entriesByID[row.id] = row
    }
    return entriesByID.values.sorted { lhs, rhs in
      if lhs.sequence == rhs.sequence {
        return lhs.id < rhs.id
      }
      return lhs.sequence < rhs.sequence
    }
  }
}

struct ConversationSnapshot {
  let timeline: ConversationTimelinePresentation?
  let conversationLoaded: Bool
  let forkOrigin: ConversationForkOriginPresentation?

  static let empty = ConversationSnapshot(
    timeline: nil,
    conversationLoaded: false,
    forkOrigin: nil
  )
}

struct ConversationForkOriginPresentation {
  let sourceSessionId: String
  let sourceEndpointId: UUID?
  let sourceName: String?
}

struct ConversationTimelinePresentation {
  let entries: [ServerConversationRowEntry]
  let contentRevision: Int
  let structureRevision: Int
  let changedEntries: [ServerConversationRowEntry]
}
