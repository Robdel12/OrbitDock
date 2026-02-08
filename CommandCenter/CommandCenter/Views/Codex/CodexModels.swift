//
//  CodexModels.swift
//  OrbitDock
//
//  Shared model and effort enums for Codex sessions.
//

import Foundation

// MARK: - Codex Model

enum CodexModel: String, CaseIterable, Identifiable {
  case `default` = ""
  case o3 = "o3"
  case o4Mini = "o4-mini"
  case gpt5Codex = "gpt-5.2-codex"
  case gpt51 = "gpt-5.1"
  case gpt4o = "gpt-4o"

  var id: String { rawValue }

  var displayName: String {
    switch self {
      case .default: "Default"
      case .o3: "o3"
      case .o4Mini: "o4-mini"
      case .gpt5Codex: "GPT-5.2 Codex"
      case .gpt51: "GPT-5.1"
      case .gpt4o: "GPT-4o"
    }
  }
}

// MARK: - Effort Level

enum EffortLevel: String, CaseIterable, Identifiable {
  case `default` = ""
  case low = "low"
  case medium = "medium"
  case high = "high"

  var id: String { rawValue }

  var displayName: String {
    switch self {
      case .default: "Default"
      case .low: "Low"
      case .medium: "Medium"
      case .high: "High"
    }
  }
}
