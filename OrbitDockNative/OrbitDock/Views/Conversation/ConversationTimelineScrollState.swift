import SwiftUI

struct ConversationTimelineScrollState {
  private let bottomSentinelID: String

  var followState = ConversationFollowState.initial
  var isNearTop = false
  var isNearBottom = true
  var commandedScrollPositionID: String?
  var observedScrollPositionID: String?
  var hasInitializedScrollPosition = false
  var isUserScrolling = false
  var hasDetachedFromBottomDuringCurrentGesture = false
  var renderedEntryLimit: Int
  var pendingHistoryReveal = false
  var pendingNearTopLoad = false

  init(bottomSentinelID: String, recentRenderWindow: Int) {
    self.bottomSentinelID = bottomSentinelID
    renderedEntryLimit = recentRenderWindow
    commandedScrollPositionID = bottomSentinelID
    observedScrollPositionID = bottomSentinelID
  }

  var scrollPositionID: String? {
    if followState.mode.isFollowing, !isUserScrolling {
      return commandedScrollPositionID ?? bottomSentinelID
    }
    return nil
  }

  mutating func setPinnedScrollPosition() {
    commandedScrollPositionID = bottomSentinelID
  }

  mutating func syncRenderedEntryLimit(totalCount: Int, recentWindow: Int) {
    renderedEntryLimit = ConversationRenderWindowPlanner.syncedLimit(
      currentLimit: renderedEntryLimit,
      totalCount: totalCount,
      recentWindow: recentWindow,
      mode: followState.mode
    )
    if followState.mode.isFollowing {
      pendingHistoryReveal = false
    }
  }

  mutating func apply(_ state: ConversationFollowState, totalCount: Int, recentWindow: Int) {
    followState = state
    syncRenderedEntryLimit(totalCount: totalCount, recentWindow: recentWindow)
  }
}
