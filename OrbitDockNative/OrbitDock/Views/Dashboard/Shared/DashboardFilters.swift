//
//  DashboardFilters.swift
//  OrbitDock
//
//  Shared sort and filter types for the live dashboard and library views.
//

import SwiftUI

enum ActiveSessionWorkbenchFilter: String, CaseIterable, Identifiable {
  case all
  case direct
  case attention
  case running
  case ready

  var id: String {
    rawValue
  }

  var title: String {
    switch self {
      case .all: "All"
      case .direct: "Direct"
      case .attention: "Attention"
      case .running: "Running"
      case .ready: "Ready"
    }
  }
}

enum ActiveSessionSort: String, CaseIterable, Identifiable {
  case name
  case status
  case recent
  case tokens
  case cost

  var id: String {
    rawValue
  }

  var label: String {
    switch self {
      case .name: "Name"
      case .status: "Status"
      case .recent: "Recent"
      case .tokens: "Tokens"
      case .cost: "Cost"
    }
  }

  var icon: String {
    switch self {
      case .name: "textformat.abc"
      case .status: "arrow.up.arrow.down"
      case .recent: "clock"
      case .tokens: "number"
      case .cost: "dollarsign"
    }
  }
}

enum ActiveSessionProviderFilter: String, CaseIterable, Identifiable {
  case all
  case claude
  case codex

  var id: String {
    rawValue
  }

  var label: String {
    switch self {
      case .all: "All"
      case .claude: "Claude"
      case .codex: "Codex"
    }
  }

  var icon: String {
    switch self {
      case .all: "circle.grid.2x2"
      case .claude: "sparkle"
      case .codex: "chevron.left.forwardslash.chevron.right"
    }
  }

  var color: Color {
    switch self {
      case .all: .textSecondary
      case .claude: .accent
      case .codex: .providerCodex
    }
  }
}
