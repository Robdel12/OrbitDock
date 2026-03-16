import SwiftUI

enum SessionProvider: String, CaseIterable, Identifiable {
  case claude
  case codex

  var id: String {
    rawValue
  }

  var displayName: String {
    switch self {
      case .claude: "Claude"
      case .codex: "Codex"
    }
  }

  var color: Color {
    switch self {
      case .claude: .providerClaude
      case .codex: .providerCodex
    }
  }

  var icon: String {
    switch self {
      case .claude: "sparkles"
      case .codex: "chevron.left.forwardslash.chevron.right"
    }
  }
}

enum ClaudeEffortLevel: String, CaseIterable, Identifiable {
  case `default` = ""
  case low
  case medium
  case high
  case max

  var id: String {
    rawValue
  }

  var displayName: String {
    switch self {
      case .default: "Default"
      case .low: "Low"
      case .medium: "Medium"
      case .high: "High"
      case .max: "Max"
    }
  }

  var description: String {
    switch self {
      case .default: "Use provider default effort"
      case .low: "Balanced speed with focused reasoning"
      case .medium: "Standard depth for general tasks"
      case .high: "In-depth analysis for complex work"
      case .max: "Maximum depth for hardest problems"
    }
  }

  var icon: String {
    switch self {
      case .default: "sparkles"
      case .low: "hare.fill"
      case .medium: "gauge.medium"
      case .high: "gauge.high"
      case .max: "flame.fill"
    }
  }

  var color: Color {
    switch self {
      case .default: .textSecondary
      case .low: .effortLow
      case .medium: .effortMedium
      case .high: .effortHigh
      case .max: .effortXHigh
    }
  }

  var serialized: String? {
    self == .default ? nil : rawValue
  }
}
