//
//  LayoutConfiguration.swift
//  OrbitDock
//
//  Layout state for the Agent Workbench.
//

import SwiftUI

// MARK: - Layout Configuration

enum LayoutConfiguration: String, CaseIterable {
  case conversationOnly
  case reviewOnly
  case split

  var showsConversation: Bool {
    self != .reviewOnly
  }

  var showsReview: Bool {
    self != .conversationOnly
  }

  var label: String {
    switch self {
      case .conversationOnly: "Conversation"
      case .reviewOnly: "Review"
      case .split: "Split"
    }
  }

  var icon: String {
    switch self {
      case .conversationOnly: "text.bubble"
      case .reviewOnly: "doc.text.magnifyingglass"
      case .split: "rectangle.split.2x1"
    }
  }
}

// MARK: - Rail Preset

enum RailPreset: String, CaseIterable {
  case planFocused
  case reviewFocused
  case triage

  var label: String {
    switch self {
      case .planFocused: "Plan"
      case .reviewFocused: "Review"
      case .triage: "Triage"
    }
  }

  var icon: String {
    switch self {
      case .planFocused: "list.bullet.clipboard"
      case .reviewFocused: "doc.badge.plus"
      case .triage: "square.stack"
    }
  }

  var expandPlan: Bool {
    self == .planFocused
  }

  var expandChanges: Bool {
    self == .reviewFocused
  }

  var expandServers: Bool {
    false
  }

  var expandSkills: Bool {
    false
  }

  var expandComments: Bool {
    self == .reviewFocused
  }
}

// MARK: - Review Navigation (Environment)

/// Environment action that lets any view request "open this file in the review canvas."
/// SessionDetailView provides this; EditCard and other tool cards consume it.
private struct ReviewNavigationKey: EnvironmentKey {
  static let defaultValue: ((String) -> Void)? = nil
}

extension EnvironmentValues {
  /// Call with a file path to open that file in the review canvas (switches to split if needed).
  var openFileInReview: ((String) -> Void)? {
    get { self[ReviewNavigationKey.self] }
    set { self[ReviewNavigationKey.self] = newValue }
  }
}

// MARK: - Input Mode

enum InputMode: Equatable {
  case prompt // Session idle, ready for new prompt
  case steer // Session working, steering active turn
  case reviewNotes // User manually switched to send review notes

  var label: String {
    switch self {
      case .prompt: "New Prompt"
      case .steer: "Steering Active Turn"
      case .reviewNotes: "Review Notes"
    }
  }

  var color: Color {
    switch self {
      case .prompt: .accent
      case .steer: .accent
      case .reviewNotes: .statusQuestion
    }
  }

  var icon: String {
    switch self {
      case .prompt: "text.bubble"
      case .steer: "arrow.uturn.right"
      case .reviewNotes: "pencil.and.outline"
    }
  }
}
