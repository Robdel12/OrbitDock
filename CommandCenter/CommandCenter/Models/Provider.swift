//
//  Provider.swift
//  OrbitDock
//
//  Multi-provider support for AI agent sessions.
//  Each provider represents a different AI service with its own rate limits.
//

import SwiftUI

/// Represents a supported AI provider
enum Provider: String, CaseIterable, Identifiable, Sendable {
  case claude
  case codex

  var id: String { rawValue }

  var displayName: String {
    switch self {
      case .claude: "Claude"
      case .codex: "Codex"
    }
  }

  var icon: String {
    switch self {
      case .claude: "brain.head.profile"
      case .codex: "chevron.left.forwardslash.chevron.right"
    }
  }

  var accentColor: Color {
    switch self {
      case .claude: .providerClaude
      case .codex: .providerCodex
    }
  }

  /// Color at different utilization thresholds
  func color(for utilization: Double) -> Color {
    if utilization >= 90 { return .statusError }
    if utilization >= 70 { return .statusWaiting }
    return accentColor
  }
}
