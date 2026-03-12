import Foundation

@MainActor
final class RootShellEffectsCoordinator {
  private let rootShellStore: RootShellStore
  private let attentionService: AttentionService
  private let notificationManager: NotificationManager
  private let toastManager: ToastManager
  private let router: AppRouter

  init(
    rootShellStore: RootShellStore,
    attentionService: AttentionService,
    notificationManager: NotificationManager,
    toastManager: ToastManager,
    router: AppRouter
  ) {
    self.rootShellStore = rootShellStore
    self.attentionService = attentionService
    self.notificationManager = notificationManager
    self.toastManager = toastManager
    self.router = router
  }

  func setCurrentSelection(_ scopedID: String?) {
    toastManager.currentSessionId = scopedID
  }

  func applyRootChange(
    previousMissionControlSessions: [RootSessionNode],
    currentMissionControlSessions: [RootSessionNode]
  ) {
    let currentAttentionSessions = currentMissionControlSessions.filter(\.needsAttention)
    let oldWaitingIDs = Set(previousMissionControlSessions.filter(\.needsAttention).map(\.scopedID))

    syncSelectionToRootShell()

    let notificationSessions = Self.mergeMissionControlSessions(
      previousSessions: previousMissionControlSessions,
      currentSessions: currentMissionControlSessions
    )

    for session in notificationSessions {
      notificationManager.updateSessionWorkStatus(session: session)
    }

    for session in currentAttentionSessions where !oldWaitingIDs.contains(session.scopedID) {
      notificationManager.notifyNeedsAttention(session: session)
    }

    for oldID in oldWaitingIDs where !currentAttentionSessions.contains(where: { $0.scopedID == oldID }) {
      notificationManager.resetNotificationState(for: oldID)
    }

    toastManager.checkForAttentionChanges(
      sessions: currentMissionControlSessions,
      previousSessions: previousMissionControlSessions
    )

    attentionService.update(sessions: currentMissionControlSessions)
  }

  private func syncSelectionToRootShell() {
    if let selectedScopedID = router.selectedScopedID,
       rootShellStore.sessionRef(for: selectedScopedID) == nil
    {
      router.goToDashboard()
    }
  }
}

private extension RootShellEffectsCoordinator {
  static func mergeMissionControlSessions(
    previousSessions: [RootSessionNode],
    currentSessions: [RootSessionNode]
  ) -> [RootSessionNode] {
    var mergedByScopedID: [String: RootSessionNode] = [:]
    var orderedScopedIDs: [String] = []

    for session in currentSessions {
      if mergedByScopedID[session.scopedID] == nil {
        orderedScopedIDs.append(session.scopedID)
      }
      mergedByScopedID[session.scopedID] = session
    }

    for session in previousSessions {
      guard mergedByScopedID[session.scopedID] == nil else { continue }
      mergedByScopedID[session.scopedID] = session
      orderedScopedIDs.append(session.scopedID)
    }

    return orderedScopedIDs.compactMap { mergedByScopedID[$0] }
  }
}
