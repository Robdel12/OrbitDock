//
//  CodexModels.swift
//  OrbitDock
//
//  Shared effort level enum for Codex sessions.
//  Models come from the server via ServerCodexModelOption.
//

import SwiftUI

// MARK: - Effort Level

enum EffortLevel: String, CaseIterable, Identifiable {
  case `default` = ""
  case none
  case minimal
  case low
  case medium
  case high
  case xhigh

  var id: String { rawValue }

  var displayName: String {
    switch self {
      case .default: "Default"
      case .none: "None"
      case .minimal: "Minimal"
      case .low: "Low"
      case .medium: "Medium"
      case .high: "High"
      case .xhigh: "XHigh"
    }
  }

  var description: String {
    switch self {
      case .default: "Use model's default reasoning"
      case .none: "No reasoning, fastest responses"
      case .minimal: "Very fast with minimal reasoning"
      case .low: "Quick responses with some reasoning"
      case .medium: "Good balance of speed and depth"
      case .high: "Deep reasoning for complex problems"
      case .xhigh: "Maximum reasoning depth"
    }
  }

  var icon: String {
    switch self {
      case .default: "sparkle"
      case .none: "bolt.fill"
      case .minimal: "hare.fill"
      case .low: "gauge.low"
      case .medium: "gauge.medium"
      case .high: "gauge.high"
      case .xhigh: "flame.fill"
    }
  }

  var color: Color {
    switch self {
      case .default: .textSecondary
      case .none: .effortNone
      case .minimal: .effortMinimal
      case .low: .effortLow
      case .medium: .effortMedium
      case .high: .effortHigh
      case .xhigh: .effortXHigh
    }
  }

  var speedLabel: String {
    switch self {
      case .default: ""
      case .none: "Instant"
      case .minimal: "Very fast"
      case .low: "Fast"
      case .medium: "Balanced"
      case .high: "Slower"
      case .xhigh: "Slowest"
    }
  }

  var isDefault: Bool { self == .medium }

  /// The serialized effort string (excluding .default which sends nil)
  var serialized: String? {
    self == .default ? nil : rawValue
  }

  /// Concrete effort levels (excludes .default)
  static var concreteCases: [EffortLevel] {
    allCases.filter { $0 != .default }
  }

  /// Index in CaseIterable for track positioning
  var index: Int {
    Self.allCases.firstIndex(of: self) ?? 0
  }
}
