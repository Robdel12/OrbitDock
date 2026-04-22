import SwiftUI

extension ConversationViewModel {
  func bind(sessionId: String?, session: ServerSessionContext, viewMode: ChatViewMode) {
    let didChange = currentSessionId != sessionId || currentSession !== session
    currentSessionId = sessionId
    currentSession = session
    currentViewMode = viewMode
    timelineViewModel.bind(sessionId: sessionId)

    if didChange {
      followState = .initial
      rowEntries = []
      structureRevision = 0
      contentRevision = 0
      lastNewestSequence = 0
      hasShownContent = false
      conversationLoaded = false
      hasMoreBefore = false
      totalRowCount = 0
      isLoadingOlder = false
      forkOrigin = nil
      refreshRunner.cancel()
      isRefreshInFlight = false
      pendingForceHTTPResync = false
      pendingForcedResyncRevision = nil
      lastCompletedForcedResyncRevision = nil
      lastCompletedUnversionedForcedResyncCursor = nil
      rebuildPresentation(changedEntries: [])
    }
  }

  func handleTimelineViewModeChange(_ viewMode: ChatViewMode) {
    currentViewMode = viewMode
    rebuildPresentation(changedEntries: [])
  }

  func applyFollowState(_ state: ConversationFollowState) {
    followState = state
  }

  func handleLoadStateChange(_ newState: ConversationLoadState) {
    if newState == .ready {
      hasShownContent = true
    }
  }
}
