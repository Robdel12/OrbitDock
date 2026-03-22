import Foundation

enum CodexApprovalPolicyEditorStyle: String, CaseIterable, Identifiable, Sendable {
  case preset
  case granular

  var id: String {
    rawValue
  }

  var displayName: String {
    switch self {
      case .preset: "Preset"
      case .granular: "Granular"
    }
  }
}

enum CodexApprovalToggleField: String, CaseIterable, Identifiable, Sendable {
  case sandboxApproval
  case rules
  case skillApproval
  case requestPermissions
  case mcpElicitations

  var id: String {
    rawValue
  }

  var title: String {
    switch self {
      case .sandboxApproval: "Sandbox escalation"
      case .rules: "Rules"
      case .skillApproval: "Skills"
      case .requestPermissions: "Permission requests"
      case .mcpElicitations: "MCP elicitations"
    }
  }

  var detail: String {
    switch self {
      case .sandboxApproval: "Keep the approval rail in play when sandbox boundaries are hit."
      case .rules: "Control whether configured rules participate in approval decisions."
      case .skillApproval: "Decide whether skill execution stays behind the approval rail."
      case .requestPermissions: "Control how Codex handles explicit permission requests."
      case .mcpElicitations: "Control whether MCP elicitation prompts stay approval-gated."
    }
  }
}

struct CodexApprovalPolicyToggleSummary: Equatable, Identifiable, Sendable {
  let field: CodexApprovalToggleField
  let isEnabled: Bool

  var id: String {
    field.id
  }

  var title: String {
    field.title
  }

  var detail: String {
    field.detail
  }

  var valueLabel: String {
    isEnabled ? "On" : "Off"
  }
}

struct CodexApprovalPolicyDraft: Equatable, Sendable {
  var style: CodexApprovalPolicyEditorStyle
  var presetMode: ServerCodexApprovalMode
  var sandboxApproval: Bool
  var rules: Bool
  var skillApproval: Bool
  var requestPermissions: Bool
  var mcpElicitations: Bool

  init(policy: ServerCodexApprovalPolicy?, fallbackPolicy: String?) {
    let resolved = ServerCodexApprovalPolicy.resolved(details: policy, fallbackPolicy: fallbackPolicy)
    switch resolved {
      case let .mode(mode):
        style = .preset
        presetMode = mode
        sandboxApproval = false
        rules = false
        skillApproval = false
        requestPermissions = false
        mcpElicitations = false
      case let .granular(granular):
        style = .granular
        presetMode = .onRequest
        sandboxApproval = granular.sandboxApproval ?? false
        rules = granular.rules ?? false
        skillApproval = granular.skillApproval ?? false
        requestPermissions = granular.requestPermissions ?? false
        mcpElicitations = granular.mcpElicitations ?? false
      case .none:
        style = .preset
        presetMode = .onRequest
        sandboxApproval = false
        rules = false
        skillApproval = false
        requestPermissions = false
        mcpElicitations = false
    }
  }

  var policy: ServerCodexApprovalPolicy {
    switch style {
      case .preset:
        .mode(presetMode)
      case .granular:
        .granular(
          ServerCodexGranularApprovalPolicy(
            sandboxApproval: sandboxApproval,
            rules: rules,
            skillApproval: skillApproval,
            requestPermissions: requestPermissions,
            mcpElicitations: mcpElicitations
          )
        )
    }
  }

  mutating func setEnabled(_ enabled: Bool, for field: CodexApprovalToggleField) {
    switch field {
      case .sandboxApproval: sandboxApproval = enabled
      case .rules: rules = enabled
      case .skillApproval: skillApproval = enabled
      case .requestPermissions: requestPermissions = enabled
      case .mcpElicitations: mcpElicitations = enabled
    }
  }

  func isEnabled(_ field: CodexApprovalToggleField) -> Bool {
    switch field {
      case .sandboxApproval: sandboxApproval
      case .rules: rules
      case .skillApproval: skillApproval
      case .requestPermissions: requestPermissions
      case .mcpElicitations: mcpElicitations
    }
  }
}

extension ServerCodexApprovalMode {
  static let allCases: [ServerCodexApprovalMode] = [
    .untrusted,
    .onFailure,
    .onRequest,
    .never,
  ]

  nonisolated init?(legacySummary: String) {
    switch legacySummary {
      case "untrusted":
        self = .untrusted
      case "on-failure", "on_failure":
        self = .onFailure
      case "on-request", "on_request":
        self = .onRequest
      case "never":
        self = .never
      default:
        return nil
    }
  }

  nonisolated var legacySummary: String {
    switch self {
      case .untrusted: "untrusted"
      case .onFailure: "on-failure"
      case .onRequest: "on-request"
      case .never: "never"
    }
  }

  nonisolated var displayName: String {
    switch self {
      case .untrusted: "Untrusted"
      case .onFailure: "On Failure"
      case .onRequest: "On Request"
      case .never: "Never Ask"
    }
  }

  nonisolated var summary: String {
    switch self {
      case .untrusted:
        "Keep the session in the most conservative review mode."
      case .onFailure:
        "Let Codex try the sandbox first, then escalate when it hits a boundary."
      case .onRequest:
        "Let Codex ask when it needs a decision instead of forcing every action through review."
      case .never:
        "Turn interactive approval prompts off for this session."
    }
  }
}

extension ServerCodexGranularApprovalPolicy {
  nonisolated var toggleSummaries: [CodexApprovalPolicyToggleSummary] {
    [
      CodexApprovalPolicyToggleSummary(
        field: .sandboxApproval,
        isEnabled: sandboxApproval ?? false
      ),
      CodexApprovalPolicyToggleSummary(
        field: .rules,
        isEnabled: rules ?? false
      ),
      CodexApprovalPolicyToggleSummary(
        field: .skillApproval,
        isEnabled: skillApproval ?? false
      ),
      CodexApprovalPolicyToggleSummary(
        field: .requestPermissions,
        isEnabled: requestPermissions ?? false
      ),
      CodexApprovalPolicyToggleSummary(
        field: .mcpElicitations,
        isEnabled: mcpElicitations ?? false
      ),
    ]
  }
}

extension ServerCodexApprovalPolicy {
  nonisolated static func resolved(
    details: ServerCodexApprovalPolicy?,
    fallbackPolicy: String?
  ) -> ServerCodexApprovalPolicy? {
    if let details {
      return details
    }
    guard let fallbackPolicy else { return nil }
    return fromLegacySummary(fallbackPolicy)
  }

  nonisolated static func fromLegacySummary(_ value: String) -> ServerCodexApprovalPolicy? {
    guard let mode = ServerCodexApprovalMode(legacySummary: value) else { return nil }
    return .mode(mode)
  }

  nonisolated var legacySummary: String {
    switch self {
      case let .mode(mode):
        mode.legacySummary
      case .granular:
        "granular"
    }
  }

  nonisolated var displayName: String {
    switch self {
      case let .mode(mode):
        mode.displayName
      case .granular:
        "Granular Review"
    }
  }

  nonisolated var summary: String {
    switch self {
      case let .mode(mode):
        mode.summary
      case .granular:
        "Each approval rail is tuned independently instead of following a single preset."
    }
  }

  nonisolated var granularPolicy: ServerCodexGranularApprovalPolicy? {
    switch self {
      case .mode:
        nil
      case let .granular(policy):
        policy
    }
  }
}

extension AutonomyLevel {
  var approvalPolicyDetails: ServerCodexApprovalPolicy? {
    approvalPolicy.flatMap(ServerCodexApprovalPolicy.fromLegacySummary)
  }
}
