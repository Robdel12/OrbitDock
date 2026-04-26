import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct ControlDeckSubmissionPlannerTests {
  @Test func steerModeRoutesToSteerAction() {
    #expect(
      ControlDeckSubmissionPlanner.action(
        for: .steer,
        intent: .message,
        sessionShellAvailable: true
      ) == .steerTurn
    )
  }

  @Test func composeModeRoutesToSubmitAction() {
    #expect(
      ControlDeckSubmissionPlanner.action(
        for: .compose,
        intent: .message,
        sessionShellAvailable: true
      ) == .submitTurn
    )
  }

  @Test func nonSteerModesNeverRouteToSteerAction() {
    #expect(
      ControlDeckSubmissionPlanner.action(
        for: .approval,
        intent: .message,
        sessionShellAvailable: true
      ) == .submitTurn
    )
    #expect(
      ControlDeckSubmissionPlanner.action(
        for: .disabled,
        intent: .message,
        sessionShellAvailable: true
      ) == .submitTurn
    )
  }

  @Test func shellIntentRoutesToShellCommandWhenAvailable() {
    #expect(
      ControlDeckSubmissionPlanner.action(
        for: .compose,
        intent: .shell,
        sessionShellAvailable: true
      ) == .submitShellCommand
    )
  }

  @Test func shellIntentFallsBackToTurnSubmissionWhenUnavailable() {
    #expect(
      ControlDeckSubmissionPlanner.action(
        for: .compose,
        intent: .shell,
        sessionShellAvailable: false
      ) == .submitTurn
    )
  }
}
