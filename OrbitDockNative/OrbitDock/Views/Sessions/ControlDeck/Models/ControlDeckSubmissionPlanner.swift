import Foundation

enum ControlDeckSubmissionIntent: Sendable, Equatable {
  case message
  case shell
}

enum ControlDeckSubmissionAction: Sendable, Equatable {
  case submitTurn
  case steerTurn
  case submitShellCommand
}

enum ControlDeckSubmissionPlanner {
  static func action(
    for mode: ControlDeckMode,
    intent: ControlDeckSubmissionIntent,
    sessionShellAvailable: Bool
  ) -> ControlDeckSubmissionAction {
    if intent == .shell, sessionShellAvailable {
      return .submitShellCommand
    }

    switch mode {
    case .steer:
      return .steerTurn
    case .compose, .approval, .disabled:
      return .submitTurn
    }
  }

  static func intent(
    for draft: ControlDeckDraft,
    sessionShellSupported: Bool
  ) -> ControlDeckSubmissionIntent {
    guard sessionShellSupported else { return .message }
    if let override = draft.submissionIntentOverride {
      return override
    }
    return detectsBangPrefixedCommand(in: draft.text) ? .shell : .message
  }

  static func normalizedShellCommand(from draft: ControlDeckDraft) -> String {
    let trimmed = draft.trimmedText
    guard trimmed.hasPrefix("!") else { return trimmed }
    return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func detectsBangPrefixedCommand(in text: String) -> Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("!")
  }
}
