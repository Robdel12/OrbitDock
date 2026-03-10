import Foundation

struct NewSessionWorktreeState: Equatable {
  var useWorktree: Bool
  var branch: String
  var baseBranch: String
  var error: String?

  static let `default` = NewSessionWorktreeState(
    useWorktree: false,
    branch: "",
    baseBranch: "",
    error: nil
  )
}

struct NewSessionLifecycleState: Equatable {
  var selectedEndpointId: UUID
  var selectedPath: String
  var selectedPathIsGit: Bool
  var providerState: NewSessionProviderState
  var worktreeState: NewSessionWorktreeState
}

struct NewSessionContinuationDefaults: Equatable {
  let projectPath: String
  let hasGitRepository: Bool
}

struct NewSessionLifecyclePlan: Equatable {
  var nextState: NewSessionLifecycleState
  var shouldRefreshEndpointData: Bool
  var shouldSyncModelSelections: Bool
}

enum NewSessionLifecyclePlanner {
  static func onAppear(
    current: NewSessionLifecycleState,
    selectableEndpoints: [ServerEndpoint],
    primaryEndpointId: UUID?,
    continuationEndpointId: UUID?,
    continuationDefaults: NewSessionContinuationDefaults?
  ) -> NewSessionLifecyclePlan {
    var nextState = current

    if let primaryEndpointId,
       selectableEndpoints.contains(where: { $0.id == primaryEndpointId }) {
      nextState.selectedEndpointId = primaryEndpointId
    }

    if let continuationEndpointId,
       selectableEndpoints.contains(where: { $0.id == continuationEndpointId }) {
      nextState.selectedEndpointId = continuationEndpointId
    }

    nextState.selectedEndpointId = normalizedEndpointID(
      currentEndpointId: nextState.selectedEndpointId,
      selectableEndpoints: selectableEndpoints,
      primaryEndpointId: primaryEndpointId
    )

    nextState = applyingContinuationDefaults(
      to: nextState,
      continuationEndpointId: continuationEndpointId,
      continuationDefaults: continuationDefaults
    )

    return NewSessionLifecyclePlan(
      nextState: nextState,
      shouldRefreshEndpointData: true,
      shouldSyncModelSelections: true
    )
  }

  static func pathChanged(
    current: NewSessionLifecycleState,
    newPath: String
  ) -> NewSessionLifecyclePlan {
    var nextState = current
    nextState.selectedPath = newPath
    nextState.worktreeState = .default
    return NewSessionLifecyclePlan(
      nextState: nextState,
      shouldRefreshEndpointData: false,
      shouldSyncModelSelections: false
    )
  }

  static func endpointChanged(
    current: NewSessionLifecycleState,
    requestedEndpointId: UUID,
    selectableEndpoints: [ServerEndpoint],
    primaryEndpointId: UUID?,
    continuationEndpointId: UUID?,
    continuationDefaults: NewSessionContinuationDefaults?
  ) -> NewSessionLifecyclePlan {
    var nextState = current
    nextState.selectedEndpointId = normalizedEndpointID(
      currentEndpointId: requestedEndpointId,
      selectableEndpoints: selectableEndpoints,
      primaryEndpointId: primaryEndpointId
    )
    nextState.selectedPath = ""
    nextState.selectedPathIsGit = true
    nextState.providerState = NewSessionProviderStatePlanner.reset()
    nextState.worktreeState = .default
    nextState = applyingContinuationDefaults(
      to: nextState,
      continuationEndpointId: continuationEndpointId,
      continuationDefaults: continuationDefaults
    )

    return NewSessionLifecyclePlan(
      nextState: nextState,
      shouldRefreshEndpointData: true,
      shouldSyncModelSelections: false
    )
  }

  static func providerChanged(
    current: NewSessionLifecycleState
  ) -> NewSessionLifecyclePlan {
    var nextState = current
    nextState.providerState = NewSessionProviderStatePlanner.reset()
    return NewSessionLifecyclePlan(
      nextState: nextState,
      shouldRefreshEndpointData: true,
      shouldSyncModelSelections: true
    )
  }

  static func normalizedEndpointID(
    currentEndpointId: UUID,
    selectableEndpoints: [ServerEndpoint],
    primaryEndpointId: UUID?
  ) -> UUID {
    guard !selectableEndpoints.isEmpty else { return currentEndpointId }

    if selectableEndpoints.contains(where: { $0.id == currentEndpointId }) {
      return currentEndpointId
    }

    if let primaryEndpointId,
       selectableEndpoints.contains(where: { $0.id == primaryEndpointId }) {
      return primaryEndpointId
    }

    return selectableEndpoints.first(where: \.isDefault)?.id
      ?? selectableEndpoints.first?.id
      ?? currentEndpointId
  }

  static func applyingContinuationDefaults(
    to current: NewSessionLifecycleState,
    continuationEndpointId: UUID?,
    continuationDefaults: NewSessionContinuationDefaults?
  ) -> NewSessionLifecycleState {
    guard let continuationEndpointId, let continuationDefaults else { return current }
    guard continuationEndpointId == current.selectedEndpointId else { return current }
    guard current.selectedPath.isEmpty else { return current }

    var nextState = current
    nextState.selectedPath = continuationDefaults.projectPath
    nextState.selectedPathIsGit = continuationDefaults.hasGitRepository
    return nextState
  }
}
