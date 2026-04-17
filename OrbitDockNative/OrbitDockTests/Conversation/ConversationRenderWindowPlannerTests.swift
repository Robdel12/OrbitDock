import Foundation
@testable import OrbitDock
import Testing

struct ConversationRenderWindowPlannerTests {
  @Test func followingAppendPreservesExpandedVisibleTail() {
    #expect(
      ConversationRenderWindowPlanner.followingAppendLimit(
        currentLimit: 140,
        totalCount: 220,
        recentWindow: 60
      ) == 140
    )
  }

  @Test func followingAppendKeepsAtLeastRecentWindowWhenConversationGrows() {
    #expect(
      ConversationRenderWindowPlanner.followingAppendLimit(
        currentLimit: 20,
        totalCount: 75,
        recentWindow: 60
      ) == 60
    )
  }

  @Test func followingAppendClampsToConversationSize() {
    #expect(
      ConversationRenderWindowPlanner.followingAppendLimit(
        currentLimit: 140,
        totalCount: 55,
        recentWindow: 60
      ) == 55
    )
  }

  @Test func syncStillUsesRecentWindowWhenFollowingNormally() {
    #expect(
      ConversationRenderWindowPlanner.syncedLimit(
        currentLimit: 140,
        totalCount: 220,
        recentWindow: 60,
        mode: .following
      ) == 60
    )
  }

  @Test func syncPreservesDetachedExpandedWindow() {
    #expect(
      ConversationRenderWindowPlanner.syncedLimit(
        currentLimit: 140,
        totalCount: 220,
        recentWindow: 60,
        mode: .detachedByUser
      ) == 140
    )
  }
}
