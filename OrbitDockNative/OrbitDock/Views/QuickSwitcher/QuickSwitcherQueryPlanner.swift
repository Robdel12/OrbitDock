import Foundation

enum QuickSwitcherSearchMode: Equatable, Sendable {
  case standard
  case quickLaunch(QuickLaunchProviderIntent)
}

enum QuickLaunchProviderIntent: String, Equatable, Sendable {
  case claude
  case codex
}

struct QuickSwitcherQueryPlan: Equatable, Sendable {
  let normalizedQuery: String
  let mode: QuickSwitcherSearchMode
}

enum QuickSwitcherQueryPlanner {
  static func plan(searchText: String) -> QuickSwitcherQueryPlan {
    let normalizedQuery = searchText
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()

    return QuickSwitcherQueryPlan(
      normalizedQuery: normalizedQuery,
      mode: classifyMode(normalizedQuery: normalizedQuery)
    )
  }

  private static func classifyMode(normalizedQuery: String) -> QuickSwitcherSearchMode {
    if normalizedQuery.hasPrefix("new o")
      || normalizedQuery.hasPrefix("new codex")
      || normalizedQuery.hasPrefix("codex")
      || normalizedQuery == "no"
    {
      return .quickLaunch(.codex)
    }

    if normalizedQuery.hasPrefix("new c") || normalizedQuery.hasPrefix("claude") || normalizedQuery == "nc" {
      return .quickLaunch(.claude)
    }

    return .standard
  }
}
