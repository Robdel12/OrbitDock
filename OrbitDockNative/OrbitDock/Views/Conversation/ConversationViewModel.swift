import Observation
import SwiftUI

@MainActor
@Observable
final class ConversationViewModel {
  var hasShownContent = false
  var currentSessionId: String?
  var currentSessionStore = SessionStore.preview()
  var timeline: ConversationTimelinePresentation?
  var entryCount = 0
  var loadState: ConversationLoadState = .empty
  var forkOrigin: ConversationForkOriginPresentation?

  @ObservationIgnored private var sessionObservationGeneration: UInt64 = 0

  private let pageSize = 50

  func bind(sessionId: String?, sessionStore: SessionStore) {
    currentSessionId = sessionId
    currentSessionStore = sessionStore
    sessionObservationGeneration &+= 1
    startObservation(generation: sessionObservationGeneration)
  }

  func handleLoadStateChange(_ newState: ConversationLoadState) {
    if newState == .ready {
      hasShownContent = true
    }
  }

  func handleEntryCountChange(oldCount: Int, newCount: Int, isPinned: Bool, unreadCount: inout Int) {
    guard !isPinned, newCount > oldCount else { return }
    unreadCount += newCount - oldCount
  }

  func loadOlderMessages() {
    guard let currentSessionId else { return }
    currentSessionStore.loadOlderMessages(sessionId: currentSessionId, limit: pageSize)
  }

  private func startObservation(generation: UInt64) {
    guard let currentSessionId else {
      apply(snapshot: .empty)
      return
    }

    let sessionStore = currentSessionStore

    withObservationTracking {
      let snapshot = makeSnapshot(
        session: sessionStore.session(currentSessionId),
        sessionStore: sessionStore,
        hasShownContent: hasShownContent
      )
      apply(snapshot: snapshot)
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, self.sessionObservationGeneration == generation else { return }
        self.startObservation(generation: generation)
      }
    }
  }

  private func makeSnapshot(
    session: SessionObservable,
    sessionStore: SessionStore,
    hasShownContent: Bool
  ) -> ConversationSnapshot {
    let timeline = ConversationTimelinePresentation(
      entries: session.rowEntries,
      contentRevision: session.rowEntriesContentRevision,
      structureRevision: session.rowEntriesStructureRevision,
      changedEntries: session.lastChangedRowEntries
    )

    let loadState: ConversationLoadState = if !session.rowEntries.isEmpty {
      .ready
    } else if hasShownContent || session.conversationLoaded {
      .empty
    } else {
      .loading
    }

    let forkOrigin: ConversationForkOriginPresentation? = if let sourceId = session.forkedFrom {
      ConversationForkOriginPresentation(
        sourceSessionId: sourceId,
        sourceEndpointId: sessionStore.endpointId,
        sourceName: sessionStore.session(sourceId).displayName
      )
    } else {
      nil
    }

    return ConversationSnapshot(
      timeline: timeline,
      entryCount: timeline.entries.count,
      loadState: loadState,
      forkOrigin: forkOrigin
    )
  }

  private func apply(snapshot: ConversationSnapshot) {
    timeline = snapshot.timeline
    entryCount = snapshot.entryCount
    loadState = snapshot.loadState
    forkOrigin = snapshot.forkOrigin
  }
}

private struct ConversationSnapshot {
  let timeline: ConversationTimelinePresentation?
  let entryCount: Int
  let loadState: ConversationLoadState
  let forkOrigin: ConversationForkOriginPresentation?

  static let empty = ConversationSnapshot(
    timeline: nil,
    entryCount: 0,
    loadState: .empty,
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
