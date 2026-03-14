import Foundation

@Observable
@MainActor
final class SubscriptionUsageService {
  private(set) var isLoading = false
  private(set) var error: (any LocalizedError)?
  private(set) var isStale = false

  struct Usage {
    let windows: [RateLimitWindow]
  }

  private(set) var usage: Usage?

  func refresh() async {
    // Stub — will fetch from GET /api/usage/claude
  }
}
