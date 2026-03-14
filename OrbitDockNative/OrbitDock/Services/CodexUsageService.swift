import Foundation

@Observable
@MainActor
final class CodexUsageService {
  private(set) var isLoading = false
  private(set) var error: (any LocalizedError)?
  private(set) var isStale = false

  struct UsageWindow {
    let usedPercent: Double
    let windowDurationMins: Int
    let resetsAt: Date?
  }

  struct Usage {
    let primary: UsageWindow?
    let secondary: UsageWindow?
  }

  private(set) var usage: Usage?

  func refresh() async {
    // Stub — will fetch from GET /api/usage/codex
  }
}
