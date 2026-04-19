//
//  ApprovalRisk.swift
//  OrbitDock
//
//  UI-facing risk tier used to tint approval cards.
//  Risk classification is computed server-side and decoded from approval preview metadata.
//

import SwiftUI

enum ApprovalRisk {
  case low
  case normal
  case high

  var tintColor: Color {
    switch self {
      case .low: .accent
      case .normal: .statusPermission
      case .high: .statusError
    }
  }

  var tintOpacity: Double {
    switch self {
      case .low: OpacityTier.subtle
      case .normal: OpacityTier.light
      case .high: OpacityTier.medium
    }
  }

  static func fromServer(
    level: ServerApprovalRiskLevel?
  ) -> ApprovalRisk {
    guard let level else {
      return .normal
    }

    switch level {
      case .low:
        return .low
      case .normal:
        return .normal
      case .high:
        return .high
    }
  }
}
