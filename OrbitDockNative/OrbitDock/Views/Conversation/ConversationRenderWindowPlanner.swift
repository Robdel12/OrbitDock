import Foundation

enum ConversationRenderWindowPlanner {
  static func syncedLimit(
    currentLimit: Int,
    totalCount: Int,
    recentWindow: Int,
    mode: ConversationFollowMode
  ) -> Int {
    guard totalCount > 0 else { return recentWindow }

    if mode.isFollowing {
      return min(totalCount, recentWindow)
    }

    return min(max(currentLimit, recentWindow), totalCount)
  }

  static func followingAppendLimit(
    currentLimit: Int,
    totalCount: Int,
    recentWindow: Int
  ) -> Int {
    guard totalCount > 0 else { return recentWindow }
    return min(totalCount, max(currentLimit, recentWindow))
  }
}
