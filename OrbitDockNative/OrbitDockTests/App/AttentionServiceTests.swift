import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct AttentionServiceTests {
  @Test func updateBuildsAttentionEventsFromRootSafeSessionState() {
    let service = AttentionService()

    let permissionSession = makeRootSessionNode(
      from: Session(
        id: "permission",
        projectPath: "/repo/permission",
        status: .active,
        workStatus: .permission,
        attentionReason: .awaitingPermission
      )
    )
    let questionSession = makeRootSessionNode(
      from: Session(
        id: "question",
        projectPath: "/repo/question",
        status: .active,
        workStatus: .waiting,
        attentionReason: .awaitingQuestion
      )
    )
    let diffSession = makeRootSessionNode(
      from: Session(
        id: "diff",
        projectPath: "/repo/diff",
        status: .active,
        workStatus: .waiting,
        attentionReason: .none
      ),
      hasTurnDiff: true
    )

    service.update(sessions: [permissionSession, questionSession, diffSession])

    #expect(service.events.contains { $0.sessionId == permissionSession.scopedID && matches($0.type, .permissionRequired) })
    #expect(service.events.contains { $0.sessionId == questionSession.scopedID && matches($0.type, .questionWaiting) })
    #expect(service.events.contains { $0.sessionId == diffSession.scopedID && matches($0.type, .unreviewedDiff) })
  }

  private func matches(_ lhs: AttentionEventType, _ rhs: AttentionEventType) -> Bool {
    switch (lhs, rhs) {
      case (.permissionRequired, .permissionRequired), (.questionWaiting, .questionWaiting), (.unreviewedDiff, .unreviewedDiff):
        return true
      default:
        return false
    }
  }
}
