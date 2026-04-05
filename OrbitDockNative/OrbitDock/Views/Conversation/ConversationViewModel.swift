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
  @ObservationIgnored private var isLoadingOlder = false

  private let pageSize = 50

  func bind(sessionId: String?, sessionStore: SessionStore, viewMode: ChatViewMode) {
    let didChange = currentSessionId != sessionId
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
      isLoadingOlder = false
      rebuildPresentation(changedEntries: [])
    }
  }

  /// Called from ConversationView's .task — bootstraps from HTTP then consumes WS row deltas.
  func startStreaming() async {
    guard let sessionId = currentSessionId else { return }
    let store = currentSessionStore

    // 1. Bootstrap: fetch initial conversation page via HTTP
    do {
      let bootstrap = try await store.clients.conversation.fetchConversationBootstrap(
        sessionId,
        limit: pageSize
      )
      rowEntries = bootstrap.rows
      hasMoreBefore = bootstrap.hasMoreBefore
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
      }
    } catch {
      netLog(.error, cat: .store, "Conversation bootstrap failed", sid: sessionId, data: [
        "error": String(describing: error),
      ])
      conversationLoaded = true
      rebuildPresentation(changedEntries: [])
      return
    }

    // 2. Stream: consume WS row deltas
    let (stream, _) = store.conversationRowChanges(for: sessionId)
    for await delta in stream {
      guard currentSessionId == sessionId else { break }
      applyDelta(delta)
    }
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
        hasMoreBefore = page.hasMoreBefore
        rowEntries.insert(contentsOf: page.rows, at: 0)
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
      structureRevision += 1
    }
    contentRevision += 1
    rebuildPresentation(changedEntries: changed)
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
