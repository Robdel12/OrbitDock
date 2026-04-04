import Foundation

// MARK: - Snapshot (top-level bootstrap response, deck-native)

struct ControlDeckSnapshot: Sendable {
  let revision: UInt64
  let sessionId: String
  let state: ControlDeckSessionState
  let capabilities: ControlDeckCapabilities
  let preferences: ControlDeckPreferences
  let tokenUsage: ControlDeckTokenUsage
  let tokenUsageSnapshotKind: ControlDeckTokenUsageSnapshotKind
  let tokenStatus: ControlDeckTokenStatus
  let pendingApproval: ControlDeckApproval?

  func replacing(
    preferences: ControlDeckPreferences? = nil,
    pendingApproval: ControlDeckApproval?? = nil
  ) -> ControlDeckSnapshot {
    ControlDeckSnapshot(
      revision: revision,
      sessionId: sessionId,
      state: state,
      capabilities: capabilities,
      preferences: preferences ?? self.preferences,
      tokenUsage: tokenUsage,
      tokenUsageSnapshotKind: tokenUsageSnapshotKind,
      tokenStatus: tokenStatus,
      pendingApproval: pendingApproval ?? self.pendingApproval
    )
  }
}

// MARK: - Session State

struct ControlDeckSessionState: Sendable {
  let provider: ControlDeckProvider
  let controlMode: ControlDeckControlMode
  let lifecycle: ControlDeckLifecycle
  let acceptsUserInput: Bool
  let steerable: Bool
  let projectPath: String
  let currentCwd: String?
  let gitBranch: String?
  let config: ControlDeckConfig
}

enum ControlDeckProvider: String, Sendable {
  case claude
  case codex
}

enum ControlDeckControlMode: String, Sendable {
  case direct
  case passive
}

enum ControlDeckLifecycle: String, Sendable {
  case open
  case resumable
  case ended
}

struct ControlDeckConfig: Sendable {
  let model: String?
  let effort: String?
  let approvalPolicy: String?
  let approvalPolicyDetails: ServerCodexApprovalPolicy?
  let sandboxMode: String?
  let approvalsReviewer: ServerCodexApprovalsReviewer?
  let permissionMode: String?
  let collaborationMode: String?
}

// MARK: - Capabilities

struct ControlDeckCapabilities: Sendable {
  let supportsSkills: Bool
  let supportsMentions: Bool
  let supportsImages: Bool
  let supportsSteer: Bool
  let allowPerTurnModelOverride: Bool
  let allowPerTurnEffortOverride: Bool
  let effortOptions: [ControlDeckPickerOption]
  let approvalModeOptions: [ControlDeckPickerOption]
  let permissionModeOptions: [ControlDeckPickerOption]
  let collaborationModeOptions: [ControlDeckPickerOption]
  let autoReviewOptions: [ControlDeckAutoReviewOption]
  let availableStatusModules: [ControlDeckStatusModule]
}

struct ControlDeckPickerOption: Identifiable, Equatable, Sendable {
  let value: String
  let label: String

  var id: String {
    value
  }
}

struct ControlDeckAutoReviewOption: Identifiable, Equatable, Sendable {
  let value: String
  let label: String
  let approvalPolicy: String?
  let sandboxMode: String?

  var id: String {
    value
  }
}

// MARK: - Preferences

struct ControlDeckPreferences: Equatable, Sendable {
  let density: ControlDeckDensity
  let showWhenEmpty: ControlDeckEmptyVisibility
  let modules: [ControlDeckModulePreference]
}

enum ControlDeckDensity: String, Sendable {
  case comfortable
  case compact
}

enum ControlDeckEmptyVisibility: String, Sendable {
  case auto
  case always
  case hidden
}

struct ControlDeckModulePreference: Equatable, Sendable {
  let module: ControlDeckStatusModule
  let visible: Bool
}

// MARK: - Token Usage

struct ControlDeckTokenUsage: Sendable {
  let inputTokens: UInt64
  let outputTokens: UInt64
  let cachedTokens: UInt64
  let contextWindow: UInt64
}

enum ControlDeckTokenUsageSnapshotKind: Sendable {
  case unknown
  case contextTurn
  case lifetimeTotals
  case mixedLegacy
  case compactionReset
}

struct ControlDeckTokenStatus: Sendable {
  let label: String
  let tone: Tone

  enum Tone: Sendable {
    case muted
    case normal
    case caution
    case critical
  }
}

// MARK: - Status Modules

enum ControlDeckStatusModule: String, Hashable, Sendable {
  case connection
  case autonomy
  case approvalMode
  case collaborationMode
  case autoReview
  case tokens
  case model
  case effort
  case branch
  case cwd
  case attachments
}
