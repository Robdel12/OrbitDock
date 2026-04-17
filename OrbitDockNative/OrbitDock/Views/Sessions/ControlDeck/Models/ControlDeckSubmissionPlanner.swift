import Foundation

enum ControlDeckSubmissionAction: Sendable, Equatable {
  case submitTurn
  case steerTurn
}

enum ControlDeckSubmissionPlanner {
  static func action(for mode: ControlDeckMode) -> ControlDeckSubmissionAction {
    switch mode {
    case .steer:
      .steerTurn
    case .compose, .approval, .disabled:
      .submitTurn
    }
  }
}
