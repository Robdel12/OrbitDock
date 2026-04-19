@testable import OrbitDock
import Testing

@MainActor
struct ControlDeckSendClusterPlannerTests {
  @Test func idleSessionsKeepTheNormalSendButtonAvailable() {
    let actions = ControlDeckSendClusterPlanner.actions(
      canInterruptSession: false,
      canSubmit: false,
      canResume: false
    )

    #expect(actions == [.send])
  }

  @Test func resumableSessionsShowResumeInsteadOfSend() {
    let actions = ControlDeckSendClusterPlanner.actions(
      canInterruptSession: false,
      canSubmit: false,
      canResume: true
    )

    #expect(actions == [.resume])
  }

  @Test func workingSessionsKeepStopVisibleWithoutADraft() {
    let actions = ControlDeckSendClusterPlanner.actions(
      canInterruptSession: true,
      canSubmit: false,
      canResume: false
    )

    #expect(actions == [.interrupt])
  }

  @Test func workingSessionsKeepStopVisibleWhileSendingASteerDraft() {
    let actions = ControlDeckSendClusterPlanner.actions(
      canInterruptSession: true,
      canSubmit: true,
      canResume: false
    )

    #expect(actions == [.interrupt, .send])
  }
}
