import Foundation

@MainActor
@Observable
final class SessionInteractionModel {
  struct PendingFollowUpTurn: Sendable {
    enum Strategy: Sendable, Equatable {
      case whenCurrentTurnEnds
      case afterInterrupt
    }

    var payload: ControlDeckSubmitEncoder.SendPayload
    var strategy: Strategy
  }

  struct BindingContext {
    let sessionId: String
    let session: ServerSessionContext
    let revision: Int
  }

  var snapshot: ControlDeckSnapshot?
  var presentation: ControlDeckPresentation?
  var skills: [ControlDeckSkill] = []
  var controls: ServerSessionControlsPayload?
  var isLoadingSkills = false
  var hasAttemptedSkillLoad = false
  var isLoading = false
  var isResuming = false
  var isSendingPendingFollowUp = false
  var lastError: String?
  var pendingFollowUpTurn: PendingFollowUpTurn?

  var pendingApproval: ControlDeckApproval? { snapshot?.pendingApproval }
  var controlMode: ControlDeckControlMode { snapshot?.state.controlMode ?? .passive }
  var lifecycle: ControlDeckLifecycle { snapshot?.state.lifecycle ?? .ended }
  var acceptsUserInput: Bool { snapshot?.state.acceptsUserInput ?? false }
  var steerable: Bool { snapshot?.state.steerable ?? false }
  var currentTurnId: String? { snapshot?.state.currentTurnId }
  var sessionShell: ControlDeckSessionShellCapability? { snapshot?.sessionShell }
  var turnControls: ControlDeckTurnControls? { snapshot?.turnControls }
  var pendingFollowUpMessage: String? {
    guard let pendingFollowUpTurn else { return nil }
    switch pendingFollowUpTurn.strategy {
      case .whenCurrentTurnEnds:
        return "Queued for the next turn when the current run finishes."
      case .afterInterrupt:
        return "Interrupting current work, then sending your queued steer as a new turn."
    }
  }

  @ObservationIgnored let refreshRunner = CoalescedRefreshRunner()
  @ObservationIgnored var currentSessionId: String?
  @ObservationIgnored var currentSession: ServerSessionContext?
  @ObservationIgnored var currentBindingRevision = 0
  @ObservationIgnored var lastLoggedSessionSignature: String?
  @ObservationIgnored var detailSnapshotSink: ((ServerSessionDetailSnapshotPayload) -> Void)?
  @ObservationIgnored var conversationRowSink: ((ServerConversationRowEntry) -> Void)?
  @ObservationIgnored var pendingFollowUpTask: Task<Void, Never>?
}

extension ControlDeckMode {
  var debugLabel: String {
    switch self {
      case .compose: "compose"
      case .steer: "steer"
      case .approval: "approval"
      case .disabled: "disabled"
    }
  }
}

enum SessionInteractionError: Error {
  case notBound
}
