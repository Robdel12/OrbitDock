import Foundation

/// Deck-native model for a pending approval request.
/// Maps from ServerApprovalRequest — no transport types leak into the deck UI.
struct ControlDeckApproval: Equatable, Sendable {
  let requestId: String
  let sessionId: String
  let kind: Kind
  let title: String
  let detail: String?

  enum Kind: Equatable, Sendable {
    /// Tool execution or patch — approve/deny
    case tool(toolName: String?, command: String?, filePath: String?, diff: String?)
    /// Question prompt — user must answer
    case question(prompts: [Prompt])
    /// Permission request — user grants/denies permissions
    case permission(reason: String?, descriptions: [String])
  }

  struct Prompt: Equatable, Sendable, Identifiable {
    let id: String
    let question: String
    let options: [String]
    let allowsMultipleSelection: Bool
    let allowsOther: Bool
    let isSecret: Bool
  }
}

/// Approval scope when granting tool permissions
enum ControlDeckApprovalScope: String, CaseIterable, Sendable {
  case turn
  case session
}
