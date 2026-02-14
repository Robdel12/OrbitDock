//
//  CapabilityBadge.swift
//  OrbitDock
//
//  Small capsule badge showing session capabilities in the header.
//

import SwiftUI

struct CapabilityBadge: View {
  let label: String
  var icon: String? = nil
  var color: Color = .accent

  var body: some View {
    HStack(spacing: 3) {
      if let icon {
        Image(systemName: icon)
          .font(.system(size: 8, weight: .semibold))
      }
      Text(label)
        .font(.system(size: 9, weight: .semibold))
    }
    .foregroundStyle(color)
    .padding(.horizontal, 6)
    .padding(.vertical, 3)
    .background(color.opacity(0.12), in: Capsule())
  }
}

// MARK: - Session Capability

enum SessionCapability: Identifiable {
  case direct
  case passive
  case canSteer
  case canApprove

  var id: String {
    switch self {
    case .direct: "direct"
    case .passive: "passive"
    case .canSteer: "canSteer"
    case .canApprove: "canApprove"
    }
  }

  var label: String {
    switch self {
    case .direct: "Direct"
    case .passive: "Passive"
    case .canSteer: "Steer"
    case .canApprove: "Approve"
    }
  }

  var icon: String? {
    switch self {
    case .direct: "bolt.fill"
    case .passive: "eye"
    case .canSteer: "arrow.uturn.right"
    case .canApprove: "lock.open.fill"
    }
  }

  var color: Color {
    switch self {
    case .direct: .accent
    case .passive: .secondary
    case .canSteer: .accent
    case .canApprove: .statusPermission
    }
  }

  /// Derive capabilities from a Session
  static func capabilities(for session: Session) -> [SessionCapability] {
    guard session.provider == .codex else { return [] }

    var caps: [SessionCapability] = []

    if session.isDirectCodex {
      caps.append(.direct)
      if session.isActive, session.workStatus == .working {
        caps.append(.canSteer)
      }
      if session.canApprove {
        caps.append(.canApprove)
      }
    } else {
      caps.append(.passive)
    }

    return caps
  }
}

#Preview {
  HStack(spacing: 6) {
    CapabilityBadge(label: "Direct", icon: "bolt.fill", color: .accent)
    CapabilityBadge(label: "Steer", icon: "arrow.uturn.right", color: .accent)
    CapabilityBadge(label: "Approve", icon: "lock.open.fill", color: .statusPermission)
    CapabilityBadge(label: "Passive", icon: "eye", color: .secondary)
  }
  .padding()
  .background(Color.backgroundSecondary)
}
