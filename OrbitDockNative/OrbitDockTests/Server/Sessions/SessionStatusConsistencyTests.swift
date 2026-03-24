import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct SessionStatusConsistencyTests {
  @Test func rootSessionNodeDisplayStatusPrefersAttentionReasonOverWorkStatus() {
    let permissionNode = makeRootSessionNode(from: Session(
      id: "permission-session",
      endpointId: UUID(),
      endpointName: nil,
      endpointConnectionStatus: .connected,
      projectPath: "/tmp/project",
      projectName: nil,
      status: .active,
      workStatus: .waiting,
      attentionReason: .awaitingPermission
    ))
    #expect(permissionNode.displayStatus == .permission)

    let questionNode = makeRootSessionNode(from: Session(
      id: "question-session",
      endpointId: UUID(),
      endpointName: nil,
      endpointConnectionStatus: .connected,
      projectPath: "/tmp/project",
      projectName: nil,
      status: .active,
      workStatus: .working,
      attentionReason: .awaitingQuestion
    ))
    #expect(questionNode.displayStatus == .question)

    let replyNode = makeRootSessionNode(from: Session(
      id: "reply-session",
      endpointId: UUID(),
      endpointName: nil,
      endpointConnectionStatus: .connected,
      projectPath: "/tmp/project",
      projectName: nil,
      status: .active,
      workStatus: .working,
      attentionReason: .awaitingReply
    ))
    #expect(replyNode.displayStatus == .reply)
  }

  @Test func notificationMessagesFollowDisplayStatusInsteadOfRawWorkStatus() {
    let permissionSession = makeRootSessionNode(from: Session(
      id: "permission-body",
      endpointId: UUID(),
      endpointName: nil,
      endpointConnectionStatus: .connected,
      projectPath: "/tmp/project",
      projectName: nil,
      status: .active,
      workStatus: .waiting,
      attentionReason: .awaitingPermission
    ))
    #expect(NotificationManager.attentionMessage(for: permissionSession) == "Needs approval to continue.")
    #expect(NotificationManager.completionMessage(for: permissionSession) == "Finished work in project.")

    let questionSession = makeRootSessionNode(from: Session(
      id: "question-body",
      endpointId: UUID(),
      endpointName: nil,
      endpointConnectionStatus: .connected,
      projectPath: "/tmp/project",
      projectName: nil,
      status: .active,
      workStatus: .waiting,
      attentionReason: .awaitingQuestion
    ))
    #expect(NotificationManager.attentionMessage(for: questionSession) == "Has a question for you.")
    #expect(NotificationManager.completionMessage(for: questionSession) == "Finished work in project.")

    let replySession = makeRootSessionNode(from: Session(
      id: "reply-body",
      endpointId: UUID(),
      endpointName: nil,
      endpointConnectionStatus: .connected,
      projectPath: "/tmp/project",
      projectName: nil,
      status: .active,
      workStatus: .working,
      attentionReason: .awaitingReply
    ))
    #expect(NotificationManager.attentionMessage(for: replySession) == "Is waiting for your reply.")
    #expect(NotificationManager.completionMessage(for: replySession) == "Finished work in project.")
  }

  @Test func workingTrackingUsesDisplayStatus() {
    let activeWorkingSession = makeRootSessionNode(from: Session(
      id: "working",
      endpointId: UUID(),
      endpointName: nil,
      endpointConnectionStatus: .connected,
      projectPath: "/tmp/project",
      projectName: nil,
      status: .active,
      workStatus: .working,
      attentionReason: .none
    ))
    #expect(NotificationManager.shouldTrackAsWorking(activeWorkingSession))

    let replySession = makeRootSessionNode(from: Session(
      id: "reply",
      endpointId: UUID(),
      endpointName: nil,
      endpointConnectionStatus: .connected,
      projectPath: "/tmp/project",
      projectName: nil,
      status: .active,
      workStatus: .working,
      attentionReason: .awaitingReply
    ))
    #expect(!NotificationManager.shouldTrackAsWorking(replySession))
  }

  @Test func passiveCodexSessionsDoNotParticipateInNotifications() {
    let passiveCodex = makeRootSessionNode(from: Session(
      id: "passive-codex",
      endpointId: UUID(),
      endpointName: nil,
      endpointConnectionStatus: .connected,
      projectPath: "/tmp/project",
      projectName: nil,
      status: .active,
      workStatus: .working,
      attentionReason: .none,
      provider: .codex,
      codexIntegrationMode: .passive
    ))

    #expect(passiveCodex.isPassiveCodex)
    #expect(!passiveCodex.allowsUserNotifications)
    #expect(!NotificationManager.shouldTrackAsWorking(passiveCodex))
  }
}
