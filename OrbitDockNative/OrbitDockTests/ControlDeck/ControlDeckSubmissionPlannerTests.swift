import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct ControlDeckSubmissionPlannerTests {
  @Test func steerModeRoutesToSteerAction() {
    #expect(ControlDeckSubmissionPlanner.action(for: .steer) == .steerTurn)
  }

  @Test func composeModeRoutesToSubmitAction() {
    #expect(ControlDeckSubmissionPlanner.action(for: .compose) == .submitTurn)
  }

  @Test func nonSteerModesNeverRouteToSteerAction() {
    #expect(ControlDeckSubmissionPlanner.action(for: .approval) == .submitTurn)
    #expect(ControlDeckSubmissionPlanner.action(for: .disabled) == .submitTurn)
  }
}
