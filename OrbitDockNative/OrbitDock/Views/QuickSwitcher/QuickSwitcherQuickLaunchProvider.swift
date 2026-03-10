import SwiftUI

enum QuickLaunchProvider: Equatable {
  case claude
  case codex

  init(intent: QuickLaunchProviderIntent) {
    switch intent {
      case .claude:
        self = .claude
      case .codex:
        self = .codex
    }
  }

  var intent: QuickLaunchProviderIntent {
    switch self {
      case .claude:
        .claude
      case .codex:
        .codex
    }
  }

  var displayName: String {
    switch self {
      case .claude: "Claude"
      case .codex: "Codex"
    }
  }

  var color: Color {
    switch self {
      case .claude: Color.providerClaude
      case .codex: Color.providerCodex
    }
  }

  var icon: String {
    switch self {
      case .claude: "sparkles"
      case .codex: "terminal.fill"
    }
  }
}
