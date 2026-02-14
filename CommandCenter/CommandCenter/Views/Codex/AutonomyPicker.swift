//
//  AutonomyPicker.swift
//  OrbitDock
//
//  Shared autonomy level enum and compact picker for Codex sessions.
//  Used in NewCodexSessionSheet (creation) and SessionDetailView (live control).
//

import SwiftUI

// MARK: - Autonomy Level

enum AutonomyLevel: String, CaseIterable, Identifiable {
  case suggest
  case autoEdit
  case fullAuto
  case fullAccess

  var id: String {
    rawValue
  }

  var displayName: String {
    switch self {
      case .suggest: "Suggest"
      case .autoEdit: "Auto Edit"
      case .fullAuto: "Full Auto"
      case .fullAccess: "Full Access"
    }
  }

  var shortName: String {
    switch self {
      case .suggest: "Suggest"
      case .autoEdit: "Auto Ed"
      case .fullAuto: "Full Au"
      case .fullAccess: "Full Ac"
    }
  }

  var icon: String {
    switch self {
      case .suggest: "lock.shield"
      case .autoEdit: "pencil.and.outline"
      case .fullAuto: "bolt.shield"
      case .fullAccess: "exclamationmark.triangle"
    }
  }

  var description: String {
    switch self {
      case .suggest: "Approves reads, asks for everything else"
      case .autoEdit: "Sandbox enforced, model decides when to ask"
      case .fullAuto: "Runs everything in sandbox, never asks"
      case .fullAccess: "No restrictions, no approvals"
    }
  }

  var approvalPolicy: String? {
    switch self {
      case .suggest: "untrusted"
      case .autoEdit: "on-request"
      case .fullAuto: "never"
      case .fullAccess: "never"
    }
  }

  var sandboxMode: String? {
    switch self {
      case .suggest: "workspace-write"
      case .autoEdit: "workspace-write"
      case .fullAuto: "workspace-write"
      case .fullAccess: "danger-full-access"
    }
  }

  /// Infer autonomy level from approval policy + sandbox mode strings
  static func from(approvalPolicy: String?, sandboxMode: String?) -> AutonomyLevel {
    switch (approvalPolicy, sandboxMode) {
      case (nil, nil), ("untrusted", _):
        .suggest
      case ("on-request", _):
        .autoEdit
      case ("never", "danger-full-access"):
        .fullAccess
      case ("never", _):
        .fullAuto
      default:
        .suggest
    }
  }
}

// MARK: - Compact Autonomy Pill

struct AutonomyPill: View {
  let sessionId: String
  @Environment(ServerAppState.self) private var serverState

  private var currentLevel: AutonomyLevel {
    serverState.session(sessionId).autonomy
  }

  var body: some View {
    Menu {
      ForEach(AutonomyLevel.allCases) { level in
        Button {
          serverState.updateSessionConfig(sessionId: sessionId, autonomy: level)
        } label: {
          Label {
            VStack(alignment: .leading) {
              Text(level.displayName)
              Text(level.description)
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          } icon: {
            Image(systemName: level.icon)
          }
        }
        .disabled(level == currentLevel)
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: currentLevel.icon)
          .font(.system(size: 10, weight: .medium))
        Text(currentLevel.displayName)
          .font(.system(size: 11, weight: .medium))
      }
      .foregroundStyle(pillForeground)
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(pillBackground, in: Capsule())
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
  }

  private var pillForeground: Color {
    currentLevel == .fullAccess ? Color.statusPermission : .secondary
  }

  private var pillBackground: Color {
    currentLevel == .fullAccess
      ? Color.statusPermission.opacity(0.15)
      : Color.surfaceHover
  }
}

#Preview {
  HStack {
    AutonomyPill(sessionId: "test")
  }
  .padding()
  .environment(ServerAppState())
}
