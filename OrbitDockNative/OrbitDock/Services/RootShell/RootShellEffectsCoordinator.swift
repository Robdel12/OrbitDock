import Foundation

@MainActor
final class RootShellEffectsCoordinator {
  private let rootShellStore: RootShellStore
  private let attentionService: AttentionService
  private let notificationManager: NotificationManager
  private let toastManager: ToastManager
  private let router: AppRouter
  private var knownMissionControlSessions: [String: RootSessionNode] = [:]

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

  func applyRootChange(update: RootShellRuntimeUpdate) {
    syncSelectionToRootShell()
    for scopedID in update.removedScopedIDs {
      knownMissionControlSessions.removeValue(forKey: scopedID)
      notificationManager.removeSessionTracking(for: scopedID)
      toastManager.removeSession(scopedID)
      attentionService.remove(sessionId: scopedID)
    }

    for session in update.upsertedSessions {
      let previous = knownMissionControlSessions[session.scopedID]

      if session.showsInMissionControl {
        knownMissionControlSessions[session.scopedID] = session
        notificationManager.updateSessionWorkStatus(session: session)
        toastManager.applySessionTransition(current: session, previous: previous)
        attentionService.apply(session: session)

        if session.needsAttention && previous?.needsAttention != true {
          notificationManager.notifyNeedsAttention(session: session)
        } else if !session.needsAttention, previous?.needsAttention == true {
          notificationManager.resetNotificationState(for: session.scopedID)
        }
      } else {
        knownMissionControlSessions.removeValue(forKey: session.scopedID)
        notificationManager.removeSessionTracking(for: session.scopedID)
        toastManager.removeSession(session.scopedID)
        attentionService.remove(sessionId: session.scopedID)
      }
    }
  }

  private func syncSelectionToRootShell() {
    if let selectedScopedID = router.selectedScopedID,
       rootShellStore.sessionRef(for: selectedScopedID) == nil
    {
      router.goToDashboard()
    }
  }
}
