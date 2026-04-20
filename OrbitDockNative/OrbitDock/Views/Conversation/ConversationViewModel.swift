import Observation
import SwiftUI

@MainActor
@Observable
final class ConversationViewModel {
  var hasShownContent = false
  var currentSessionId: String?
  var currentSession: ServerSessionContext
  var currentViewMode: ChatViewMode = .focused
  var hasTimeline = false
  var timelineViewModel = ConversationTimelineViewModel()
  var followState = ConversationFollowState.initial
  var latestAppendEvent: ConversationLatestAppendEvent?
  var loadState: ConversationLoadState = .empty
  var forkOrigin: ConversationForkOriginPresentation?

  @ObservationIgnored var rowEntries: [ServerConversationRowEntry] = []
  @ObservationIgnored var structureRevision: Int = 0
  @ObservationIgnored var contentRevision: Int = 0
  @ObservationIgnored var lastNewestSequence: UInt64 = 0
  @ObservationIgnored var conversationLoaded = false
  @ObservationIgnored var hasMoreBefore = false
  @ObservationIgnored var totalRowCount: UInt64 = 0
  @ObservationIgnored var isLoadingOlder = false
  @ObservationIgnored let refreshRunner = CoalescedRefreshRunner()
  @ObservationIgnored var isRefreshInFlight = false
  @ObservationIgnored var pendingForceHTTPResync = false
  @ObservationIgnored var pendingForcedResyncRevision: UInt64?
  @ObservationIgnored var lastCompletedForcedResyncRevision: UInt64?
  @ObservationIgnored var lastCompletedUnversionedForcedResyncCursor: UInt64?

  let pageSize = 50

  init(
    sessionId: String?,
    session: ServerSessionContext,
    viewMode: ChatViewMode
  ) {
    currentSessionId = sessionId
    currentSession = session
    currentViewMode = viewMode
  }

  convenience init() {
    self.init(
      sessionId: nil,
      session: ServerSessionContext.preview(),
      viewMode: .focused
    )
  }
}
