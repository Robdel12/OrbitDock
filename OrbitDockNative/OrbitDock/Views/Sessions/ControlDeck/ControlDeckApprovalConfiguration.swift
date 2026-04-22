import SwiftUI

extension View {
  @ViewBuilder
  func controlDeckPillShadow(if condition: Bool) -> some View {
    if condition {
      self
    } else {
      self
    }
  }
}

enum CodexApprovalsReviewer: String, CaseIterable, Identifiable {
  case user
  case guardianSubagent = "guardian_subagent"

  var id: String { rawValue }

  var displayName: String {
    switch self {
      case .user: "You Review"
      case .guardianSubagent: "Auto-review"
    }
  }

  var compactStatusName: String {
    switch self {
      case .user: "You"
      case .guardianSubagent: "Auto-review"
    }
  }

  var icon: String {
    switch self {
      case .user: "person.crop.circle"
      case .guardianSubagent: "shield.lefthalf.filled"
    }
  }

  var color: Color {
    switch self {
      case .user: .textSecondary
      case .guardianSubagent: .autonomyGuarded
    }
  }

  var description: String {
    switch self {
      case .user:
        "Approval requests come straight to you when Codex needs a review decision."
      case .guardianSubagent:
        "Codex can review approval requests first, gathering context and applying a risk-based decision before involving you."
    }
  }

  static func from(rawValue: String?) -> CodexApprovalsReviewer {
    guard let rawValue, let reviewer = CodexApprovalsReviewer(rawValue: rawValue) else {
      return .user
    }
    return reviewer
  }
}

enum CodexApprovalMode: String, CaseIterable, Identifiable {
  case untrusted
  case onFailure = "on-failure"
  case onRequest = "on-request"
  case never

  var id: String {
    rawValue
  }

  var displayName: String {
    switch self {
      case .untrusted: "Review Writes"
      case .onFailure: "Ask If Blocked"
      case .onRequest: "Ask When Useful"
      case .never: "Don't Interrupt"
    }
  }

  var compactStatusName: String {
    switch self {
      case .untrusted: "Writes"
      case .onFailure: "Blocked"
      case .onRequest: "Useful"
      case .never: "Quiet"
    }
  }

  var icon: String {
    switch self {
      case .untrusted: "lock.shield.fill"
      case .onFailure: "shield.lefthalf.filled"
      case .onRequest: "checkmark.shield.fill"
      case .never: "bolt.fill"
    }
  }

  var color: Color {
    switch self {
      case .untrusted: .autonomyLocked
      case .onFailure: .autonomyGuarded
      case .onRequest: .autonomyAutonomous
      case .never: .autonomyFullAuto
    }
  }

  var description: String {
    switch self {
      case .untrusted:
        "Reads can continue quietly, but Codex stops and asks before it edits files, writes data, or runs commands."
      case .onFailure:
        "Codex tries the work inside the sandbox first. You only get interrupted when the sandbox blocks what it wants to do."
      case .onRequest:
        "Codex can choose to pause and ask when it thinks a handoff is useful, even if the sandbox has not blocked the work."
      case .never:
        "Codex will not stop to ask for approval. Use this only when you intentionally want uninterrupted execution."
    }
  }

  static func from(rawValue: String?) -> CodexApprovalMode {
    parse(rawValue) ?? .onRequest
  }

  static func supportedCases(from options: [ControlDeckStatusModuleItem.Option]) -> [CodexApprovalMode] {
    let modes = options.compactMap { parse($0.value) }
    return modes.isEmpty ? allCases : modes
  }

  private static func parse(_ rawValue: String?) -> CodexApprovalMode? {
    guard let rawValue else { return nil }
    let normalized = rawValue
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: "_", with: "-")
      .replacingOccurrences(of: " ", with: "-")
    if let mode = CodexApprovalMode(rawValue: normalized) {
      return mode
    }
    switch normalized {
      case "onrequest":
        return .onRequest
      case "onfailure":
        return .onFailure
      case "unless-trusted":
        return .untrusted
      default:
        return nil
    }
  }
}

extension ServerCodexSandboxPolicy {
  static var controlDeckModes: [ServerCodexSandboxMode] {
    [
      .dangerFullAccess,
      .workspaceWrite,
      .readOnly,
      .externalSandbox,
    ]
  }

  static var controlDeckOptions: [ServerCodexSandboxPolicy] {
    [
      ServerCodexSandboxPolicy(mode: .dangerFullAccess, networkAccess: true),
      ServerCodexSandboxPolicy(mode: .workspaceWrite, networkAccess: false),
      ServerCodexSandboxPolicy(mode: .workspaceWrite, networkAccess: true),
      ServerCodexSandboxPolicy(mode: .readOnly, networkAccess: false),
      ServerCodexSandboxPolicy(mode: .readOnly, networkAccess: true),
      ServerCodexSandboxPolicy(mode: .externalSandbox, networkAccess: false),
      ServerCodexSandboxPolicy(mode: .externalSandbox, networkAccess: true),
    ]
  }

  func with(mode: ServerCodexSandboxMode, networkAccess: Bool) -> ServerCodexSandboxPolicy {
    ServerCodexSandboxPolicy(
      mode: mode,
      networkAccess: mode == .dangerFullAccess ? true : networkAccess
    )
  }

  func with(networkAccess: Bool) -> ServerCodexSandboxPolicy {
    ServerCodexSandboxPolicy(
      mode: mode,
      networkAccess: mode == .dangerFullAccess ? true : networkAccess
    )
  }

  var controlDeckIcon: String {
    switch mode {
      case .dangerFullAccess: "exclamationmark.triangle.fill"
      case .workspaceWrite: "square.and.pencil"
      case .readOnly: "doc.text.fill"
      case .externalSandbox: "shippingbox.fill"
    }
  }

  var controlDeckTint: Color {
    switch (mode, networkAccess) {
      case (.dangerFullAccess, _): .statusError
      case (.workspaceWrite, true): .autonomyAutonomous
      case (.workspaceWrite, false): .autonomyGuarded
      case (.readOnly, true): .feedbackWarning
      case (.readOnly, false): .textSecondary
      case (.externalSandbox, true): .accent
      case (.externalSandbox, false): .textTertiary
    }
  }
}

extension ServerCodexSandboxMode {
  var controlDeckIcon: String {
    switch self {
      case .dangerFullAccess: "exclamationmark.triangle.fill"
      case .workspaceWrite: "square.and.pencil"
      case .readOnly: "doc.text.fill"
      case .externalSandbox: "shippingbox.fill"
    }
  }

  var controlDeckTint: Color {
    switch self {
      case .dangerFullAccess: .statusError
      case .workspaceWrite: .autonomyAutonomous
      case .readOnly: .feedbackWarning
      case .externalSandbox: .accent
    }
  }

  var shortDescription: String {
    switch self {
      case .dangerFullAccess:
        "No filesystem sandbox. Codex can read, write, and run with full network access."
      case .workspaceWrite:
        "Codex can edit files in your workspace only. System locations stay sandboxed."
      case .readOnly:
        "Codex can inspect files but cannot write changes."
      case .externalSandbox:
        "Codex runs with an externally managed sandbox policy."
    }
  }
}

extension CodexApprovalMode {
  var shortDescription: String { description }
}

extension CodexApprovalsReviewer {
  var shortDescription: String { description }
}
