import Foundation

/// Deck-native model for a pending approval request.
/// Maps from ServerApprovalRequest — no transport types leak into the deck UI.
struct ControlDeckApproval: Equatable, Sendable {
  let requestId: String
  let sessionId: String
  let kind: Kind
  let title: String
  let detail: String?

  // MARK: - Risk Assessment

  let riskLevel: RiskLevel
  let riskFindings: [String]

  // MARK: - Preview Context

  let previewType: PreviewType
  /// Human-readable scope description (e.g., "this file", "matching pattern")
  let decisionScope: String?
  /// What "Always Allow" would permit (e.g., ["Bash", "in ~/Developer/*"])
  let proposedAmendment: [String]?

  // MARK: - MCP Context

  let mcpServerName: String?
  let elicitation: Elicitation?

  // MARK: - Network Context

  let networkHost: String?
  let networkProtocol: String?

  enum Kind: Equatable, Sendable {
    /// Tool execution — approve/deny bash commands, etc.
    case tool(ToolApproval)
    /// File patch — approve/deny file edits with diff
    case patch(PatchApproval)
    /// Question prompt — user must answer
    case question(prompts: [Prompt])
    /// Permission request — user grants/denies grouped permissions
    case permission(PermissionApproval)
  }

  // MARK: - Tool Approval

  struct ToolApproval: Equatable, Sendable {
    let toolName: String?
    let command: String?
    let filePath: String?
    /// For multi-step commands (e.g., `npm install && npm test`)
    let commandChain: [CommandSegment]
  }

  struct CommandSegment: Equatable, Sendable, Identifiable {
    var id: String { "\(index)-\(command)" }
    let index: Int
    let command: String
    /// Operator connecting to previous command: "&&", "||", "|"
    let chainOperator: String?

    var operatorLabel: String? {
      switch chainOperator {
        case "&&": "then"
        case "||": "if previous fails"
        case "|": "pipe to"
        default: nil
      }
    }
  }

  // MARK: - Patch Approval

  struct PatchApproval: Equatable, Sendable {
    let toolName: String?
    let filePath: String?
    let diff: String?
  }

  // MARK: - Question Prompt

  struct Prompt: Equatable, Sendable, Identifiable {
    let id: String
    let header: String?
    let question: String
    let options: [PromptOption]
    let allowsMultipleSelection: Bool
    let allowsOther: Bool
    let isSecret: Bool

    /// Whether this prompt expects free-form text input
    var isFreeForm: Bool { options.isEmpty }
  }

  struct PromptOption: Equatable, Sendable, Identifiable {
    var id: String { label }
    let label: String
    let description: String?
  }

  // MARK: - Permission Approval

  struct PermissionApproval: Equatable, Sendable {
    let reason: String?
    let groups: [PermissionGroup]
  }

  struct PermissionGroup: Equatable, Sendable, Identifiable {
    var id: String { category.rawValue }
    let category: PermissionCategory
    let items: [PermissionItem]
  }

  enum PermissionCategory: String, Sendable {
    case network
    case filesystem
    case macOs
    case generic

    var title: String {
      switch self {
        case .network: "Network"
        case .filesystem: "Filesystem"
        case .macOs: "macOS"
        case .generic: "Permissions"
      }
    }

    var icon: String {
      switch self {
        case .network: "network"
        case .filesystem: "folder"
        case .macOs: "apple.logo"
        case .generic: "lock.shield"
      }
    }
  }

  struct PermissionItem: Equatable, Sendable, Identifiable {
    var id: String { "\(action)-\(target)" }
    let action: String // "read", "write", "access", etc.
    let target: String // path, host, entitlement name
  }

  // MARK: - MCP Elicitation

  struct Elicitation: Equatable, Sendable {
    let mode: Mode
    let url: String?
    let message: String?

    enum Mode: String, Sendable {
      case form
      case url
      case unknown
    }
  }

  // MARK: - Risk Level

  enum RiskLevel: String, Sendable {
    case low
    case normal
    case high

    var isElevated: Bool { self == .normal || self == .high }
  }

  // MARK: - Preview Type

  enum PreviewType: String, Sendable {
    case shellCommand
    case diff
    case url
    case searchQuery
    case pattern
    case prompt
    case value
    case filePath
    case action
  }
}

/// Approval scope when granting tool permissions
enum ControlDeckApprovalScope: String, CaseIterable, Sendable {
  case turn
  case session
}
