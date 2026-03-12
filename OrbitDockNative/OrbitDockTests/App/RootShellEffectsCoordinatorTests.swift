import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct RootShellEffectsCoordinatorTests {
  @Test func upsertingAttentionSessionCreatesUserFacingAttentionState() {
    let rootShellStore = RootShellStore()
    let attentionService = AttentionService()
    let toastManager = ToastManager()
    let router = AppRouter()
    let coordinator = RootShellEffectsCoordinator(
      rootShellStore: rootShellStore,
      attentionService: attentionService,
      notificationManager: NotificationManager(
        isAuthorized: false,
        shouldRequestAuthorizationOnStart: false
      ),
      toastManager: toastManager,
      router: router
    )

    let session = makeRootSessionNode(from: Session(
      id: "attention-session",
      projectPath: "/repo/attention",
      status: .active,
      workStatus: .permission,
      attentionReason: .awaitingPermission
    ))

    coordinator.applyRootChange(update: RootShellRuntimeUpdate(
      upsertedSessions: [session],
      removedScopedIDs: []
    ))

    #expect(attentionService.events(for: session.scopedID).count == 1)
    #expect(toastManager.toasts.map(\.sessionId) == [session.scopedID])
  }

  @Test func removingSessionClearsAttentionAndToastState() {
    let rootShellStore = RootShellStore()
    let attentionService = AttentionService()
    let toastManager = ToastManager()
    let router = AppRouter()
    let coordinator = RootShellEffectsCoordinator(
      rootShellStore: rootShellStore,
      attentionService: attentionService,
      notificationManager: NotificationManager(
        isAuthorized: false,
        shouldRequestAuthorizationOnStart: false
      ),
      toastManager: toastManager,
      router: router
    )

    let session = makeRootSessionNode(from: Session(
      id: "attention-session",
      projectPath: "/repo/attention",
      status: .active,
      workStatus: .permission,
      attentionReason: .awaitingPermission
    ))

    coordinator.applyRootChange(update: RootShellRuntimeUpdate(
      upsertedSessions: [session],
      removedScopedIDs: []
    ))
    coordinator.applyRootChange(update: RootShellRuntimeUpdate(
      upsertedSessions: [],
      removedScopedIDs: [session.scopedID]
    ))

    #expect(attentionService.events(for: session.scopedID).isEmpty)
    #expect(toastManager.toasts.isEmpty)
  }
}
