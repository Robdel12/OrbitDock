import Foundation

struct SessionControlState: Equatable {
  var approvalVersion: UInt64
  var approvalPolicy: String?
  var sandboxMode: String?
  var permissionModeRaw: String?
  var autonomy: AutonomyLevel
  var autonomyConfiguredOnServer: Bool
  var pendingApprovalId: String?

  var permissionMode: ClaudePermissionMode {
    ClaudePermissionMode(rawValue: permissionModeRaw ?? ClaudePermissionMode.default.rawValue) ?? .default
  }
}

enum SessionPendingApprovalChange {
  case none
  case set(ServerApprovalRequest)
  case clear(resetAttention: Bool)
}

struct SessionControlTransition {
  var nextState: SessionControlState
  var approvalChange: SessionPendingApprovalChange = .none
}

enum SessionControlStateReducer {
  static func snapshotTransition(
    current: SessionControlState,
    snapshot: ServerSessionState,
    supportsServerControlConfiguration: Bool
  ) -> SessionControlTransition {
    var nextState = current
    nextState.approvalVersion = snapshot.approvalVersion ?? current.approvalVersion
    nextState.pendingApprovalId = snapshot.pendingApproval?.id ?? snapshot.pendingApprovalId
    nextState.permissionModeRaw = snapshot.permissionMode

    if supportsServerControlConfiguration {
      nextState.approvalPolicy = snapshot.approvalPolicy
      nextState.sandboxMode = snapshot.sandboxMode
      nextState.autonomy = AutonomyLevel.from(
        approvalPolicy: snapshot.approvalPolicy,
        sandboxMode: snapshot.sandboxMode
      )
      nextState.autonomyConfiguredOnServer = true
    }

    if let request = snapshot.pendingApproval {
      return SessionControlTransition(
        nextState: nextState,
        approvalChange: .set(request)
      )
    }

    return SessionControlTransition(
      nextState: nextState,
      approvalChange: .clear(resetAttention: false)
    )
  }

  static func deltaTransition(
    current: SessionControlState,
    changes: ServerStateChanges,
    summaryStillBlocked: Bool
  ) -> SessionControlTransition {
    var nextState = current
    var transition = SessionControlTransition(nextState: current)

    if let approvalPolicy = changes.approvalPolicy {
      nextState.approvalPolicy = approvalPolicy
    }

    if let sandboxMode = changes.sandboxMode {
      nextState.sandboxMode = sandboxMode
    }

    if changes.approvalPolicy != nil || changes.sandboxMode != nil {
      nextState.autonomy = AutonomyLevel.from(
        approvalPolicy: nextState.approvalPolicy,
        sandboxMode: nextState.sandboxMode
      )
      nextState.autonomyConfiguredOnServer = true
    }

    if let permissionMode = changes.permissionMode {
      nextState.permissionModeRaw = permissionMode
    }

    if let pendingApproval = changes.pendingApproval {
      let incomingVersion = changes.approvalVersion ?? 0
      let isStale = incomingVersion > 0 && incomingVersion < current.approvalVersion
      if isStale {
        return SessionControlTransition(nextState: current)
      }

      if incomingVersion > 0 {
        nextState.approvalVersion = incomingVersion
      }

      switch pendingApproval {
        case let .some(request):
          nextState.pendingApprovalId = request.id
          transition.approvalChange = .set(request)
        case .none:
          nextState.pendingApprovalId = nil
          guard !summaryStillBlocked else { break }
          transition.approvalChange = .clear(resetAttention: false)
      }
    } else if !summaryStillBlocked, current.pendingApprovalId != nil {
      nextState.pendingApprovalId = nil
      transition.approvalChange = .clear(resetAttention: false)
    }

    transition.nextState = nextState
    return transition
  }

  static func approvalRequestedTransition(
    current: SessionControlState,
    request: ServerApprovalRequest,
    version: UInt64?
  ) -> SessionControlTransition? {
    var nextState = current
    if let version, version > 0 {
      if version < current.approvalVersion {
        return nil
      }
      nextState.approvalVersion = version
    }
    nextState.pendingApprovalId = request.id

    return SessionControlTransition(
      nextState: nextState,
      approvalChange: .set(request)
    )
  }

  static func approvalDecisionTransition(
    current: SessionControlState,
    requestId: String,
    activeRequestId: String?,
    version: UInt64
  ) -> SessionControlTransition {
    var nextState = current
    nextState.approvalVersion = max(current.approvalVersion, version)

    guard current.pendingApprovalId == requestId, activeRequestId == nil else {
      return SessionControlTransition(nextState: nextState)
    }

    nextState.pendingApprovalId = nil
    return SessionControlTransition(
      nextState: nextState,
      approvalChange: .clear(resetAttention: true)
    )
  }

  static func optimisticPermissionModeTransition(
    current: SessionControlState,
    mode: ClaudePermissionMode
  ) -> SessionControlTransition {
    var nextState = current
    nextState.permissionModeRaw = mode.rawValue
    return SessionControlTransition(nextState: nextState)
  }
}
