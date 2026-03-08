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
    let permissionSession = Session(
      id: "permission-body",
      endpointId: UUID(),
      endpointConnectionStatus: .connected,
      projectPath: "/tmp/project",
      status: .active,
      workStatus: .waiting,
      attentionReason: .awaitingPermission
    )
    #expect(NotificationManager.attentionMessage(for: permissionSession) == "Waiting for permission approval")
    #expect(NotificationManager.completionMessage(for: permissionSession) == "Needs permission to continue")

    let questionSession = Session(
      id: "question-body",
      endpointId: UUID(),
      endpointConnectionStatus: .connected,
      projectPath: "/tmp/project",
      status: .active,
      workStatus: .waiting,
      attentionReason: .awaitingQuestion
    )
    #expect(NotificationManager.attentionMessage(for: questionSession) == "Waiting for your answer")
    #expect(NotificationManager.completionMessage(for: questionSession) == "Asked a question")

    let replySession = Session(
      id: "reply-body",
      endpointId: UUID(),
      endpointConnectionStatus: .connected,
      projectPath: "/tmp/project",
      status: .active,
      workStatus: .working,
      attentionReason: .awaitingReply
    )
    #expect(NotificationManager.attentionMessage(for: replySession) == "Waiting for your input")
    #expect(NotificationManager.completionMessage(for: replySession) == "Ready for your next prompt")
  }

  @Test func workingTrackingUsesDisplayStatus() {
    let activeWorkingSession = Session(
      id: "working",
      endpointId: UUID(),
      endpointConnectionStatus: .connected,
      projectPath: "/tmp/project",
      status: .active,
      workStatus: .working,
      attentionReason: .none
    )
    #expect(NotificationManager.shouldTrackAsWorking(activeWorkingSession))

    let replySession = Session(
      id: "reply",
      endpointId: UUID(),
      endpointConnectionStatus: .connected,
      projectPath: "/tmp/project",
      status: .active,
      workStatus: .working,
      attentionReason: .awaitingReply
    )
    #expect(!NotificationManager.shouldTrackAsWorking(replySession))
  }
}
