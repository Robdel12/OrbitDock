import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct SessionStatusConsistencyTests {
  @Test func sessionDisplayStatusPrefersAttentionReasonOverWorkStatus() {
    let permissionSession = Session(
      id: "permission-session",
      projectPath: "/tmp/project",
      status: .active,
      workStatus: .waiting,
      attentionReason: .awaitingPermission
    )
    #expect(SessionDisplayStatus.from(permissionSession) == .permission)

    let questionSession = Session(
      id: "question-session",
      projectPath: "/tmp/project",
      status: .active,
      workStatus: .working,
      attentionReason: .awaitingQuestion
    )
    #expect(SessionDisplayStatus.from(questionSession) == .question)

    let replySession = Session(
      id: "reply-session",
      projectPath: "/tmp/project",
      status: .active,
      workStatus: .working,
      attentionReason: .awaitingReply
    )
    #expect(SessionDisplayStatus.from(replySession) == .reply)
  }

  @Test func notificationMessagesFollowDisplayStatusInsteadOfRawWorkStatus() {
    let permissionSession = RootSessionNode(session: Session(
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

    let questionSession = RootSessionNode(session: Session(
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

    let replySession = RootSessionNode(session: Session(
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
    let activeWorkingSession = RootSessionNode(session: Session(
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

    let replySession = RootSessionNode(session: Session(
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
    let passiveCodex = RootSessionNode(session: Session(
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
