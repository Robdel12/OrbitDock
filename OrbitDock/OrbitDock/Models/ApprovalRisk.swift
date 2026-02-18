//
//  ApprovalRisk.swift
//  OrbitDock
//
//  Risk classifier for Codex approval requests.
//  Maps approval type + command content to visual risk tiers.
//

import SwiftUI

enum ApprovalRisk {
  case low // questions, read-only tools
  case normal // standard file edits, safe bash
  case high // destructive bash patterns

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
}

private let destructivePatterns: [String] = [
  "rm -rf",
  "git push --force",
  "git push -f",
  "git reset --hard",
  "sudo ",
  "DROP TABLE",
  "DROP DATABASE",
  "chmod 777",
  "curl|sh",
  "curl | sh",
  "wget|sh",
  "wget | sh",
  "dd if=",
  "> /dev/",
  "mkfs",
  ":(){ :|:& };:",
]

func classifyApprovalRisk(type: ServerApprovalType, command: String?) -> ApprovalRisk {
  switch type {
    case .question:
      return .low

    case .patch:
      return .normal

    case .exec:
      guard let cmd = command?.lowercased() else { return .normal }
      for pattern in destructivePatterns {
        if cmd.contains(pattern.lowercased()) {
          return .high
        }
      }
      return .normal
  }
}
