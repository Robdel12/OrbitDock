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

  @ObservationIgnored private var sessionObservationGeneration: UInt64 = 0
  @ObservationIgnored private var lastStructureRevision = 0
  @ObservationIgnored private var lastContentRevision = 0
  @ObservationIgnored private var lastNewestSequence: UInt64 = 0

  private let pageSize = 50

  func bind(sessionId: String?, sessionStore: SessionStore, viewMode: ChatViewMode) {
    currentSessionId = sessionId
    currentSessionStore = sessionStore
    currentViewMode = viewMode
    timelineViewModel.bind(sessionId: sessionId)
    sessionObservationGeneration &+= 1
    startObservation(generation: sessionObservationGeneration)
  }

  func handleTimelineViewModeChange(_ viewMode: ChatViewMode) {
    currentViewMode = viewMode
    guard let currentSessionId else { return }
    let session = currentSessionStore.session(currentSessionId)
    timelineViewModel.apply(
      presentation: ConversationTimelinePresentation(
        entries: session.rowEntries,
        contentRevision: session.rowEntriesContentRevision,
        structureRevision: session.rowEntriesStructureRevision,
        changedEntries: session.lastChangedRowEntries
      ),
      viewMode: viewMode
    )
  }

  func handleLoadStateChange(_ newState: ConversationLoadState) {
    if newState == .ready {
      hasShownContent = true
    }
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

    // Read the snapshot inside the tracking block so observation is registered
    // for changes to the authoritative SessionObservable. Apply it OUTSIDE so
    // that writes to self-properties (timeline, loadState, etc.) don't consume
    // the one-shot onChange before the tracked property can trigger it.
    let snapshot = withObservationTracking {
      Self.buildSnapshot(session: sessionStore.session(currentSessionId), sessionStore: sessionStore)
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, self.sessionObservationGeneration == generation else { return }
        self.startObservation(generation: generation)
      }
    }

    apply(snapshot: snapshot)
  }

  private func apply(snapshot: ConversationSnapshot) {
    let previousStructureRevision = lastStructureRevision
    let previousNewestSequence = lastNewestSequence
    let nextLoadState: ConversationLoadState = if let timeline = snapshot.timeline, !timeline.entries.isEmpty {
      .ready
    } else if hasShownContent || snapshot.conversationLoaded {
      .empty
    } else {
      .loading
    }

    let incomingStructureRevision = snapshot.timeline?.structureRevision ?? 0
    let incomingContentRevision = snapshot.timeline?.contentRevision ?? 0
    let incomingHasTimeline = snapshot.timeline != nil

    // Full skip — nothing changed at all (same revisions, same load state).
    if hasTimeline == incomingHasTimeline,
       lastStructureRevision == incomingStructureRevision,
       lastContentRevision == incomingContentRevision,
       loadState == nextLoadState
    {
      return
    }

    hasTimeline = incomingHasTimeline
    if let timeline = snapshot.timeline {
      // Always apply so content-only changes (streaming) reach the view.
      timelineViewModel.apply(presentation: timeline, viewMode: currentViewMode)

      // Only check for appended entries on structural changes — content-only
      // updates (streaming text) don't add rows.
      if previousStructureRevision != timeline.structureRevision {
        let appendedCount = timeline.changedEntries.filter { $0.sequence > previousNewestSequence }.count
        if appendedCount > 0 {
          latestAppendEvent = ConversationLatestAppendEvent(
            count: appendedCount,
            nonce: (latestAppendEvent?.nonce ?? 0) + 1
          )
        }
      }
      lastStructureRevision = timeline.structureRevision
      lastContentRevision = timeline.contentRevision
      lastNewestSequence = timeline.entries.last?.sequence ?? 0
    } else {
      timelineViewModel.clearSession()
      lastStructureRevision = 0
      lastContentRevision = 0
      lastNewestSequence = 0
    }
    if loadState != nextLoadState {
      loadState = nextLoadState
    }
    forkOrigin = snapshot.forkOrigin
  }

  private static func buildSnapshot(
    session: SessionObservable,
    sessionStore: SessionStore
  ) -> ConversationSnapshot {
    let timeline = ConversationTimelinePresentation(
      entries: session.rowEntries,
      contentRevision: session.rowEntriesContentRevision,
      structureRevision: session.rowEntriesStructureRevision,
      changedEntries: session.lastChangedRowEntries
    )

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
      conversationLoaded: session.conversationLoaded,
      forkOrigin: forkOrigin
    )
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
