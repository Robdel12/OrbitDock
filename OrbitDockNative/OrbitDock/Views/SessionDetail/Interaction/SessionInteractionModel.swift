import Foundation

@MainActor
@Observable
final class SessionInteractionModel {
  struct BindingContext {
    let sessionId: String
    let session: ServerSessionContext
    let revision: Int
  }

  var snapshot: ControlDeckSnapshot?
  var presentation: ControlDeckPresentation?
  var skills: [ControlDeckSkill] = []
  var isLoadingSkills = false
  var isLoading = false
  var isResuming = false
  var lastError: String?

  var pendingApproval: ControlDeckApproval? { snapshot?.pendingApproval }
  var controlMode: ControlDeckControlMode { snapshot?.state.controlMode ?? .passive }
  var lifecycle: ControlDeckLifecycle { snapshot?.state.lifecycle ?? .ended }
  var acceptsUserInput: Bool { snapshot?.state.acceptsUserInput ?? false }
  var steerable: Bool { snapshot?.state.steerable ?? false }

  @ObservationIgnored let refreshRunner = CoalescedRefreshRunner()
  @ObservationIgnored var currentSessionId: String?
  @ObservationIgnored var currentSession: ServerSessionContext?
  @ObservationIgnored var currentBindingRevision = 0
  @ObservationIgnored var lastLoggedSessionSignature: String?
  @ObservationIgnored var detailSnapshotSink: ((ServerSessionDetailSnapshotPayload) -> Void)?
  @ObservationIgnored var conversationRowSink: ((ServerConversationRowEntry) -> Void)?
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
