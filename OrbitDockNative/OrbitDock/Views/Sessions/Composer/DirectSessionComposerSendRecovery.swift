import Foundation

enum DirectSessionComposerSendRecovery {
  static func trackAttempt(
    in state: inout DirectSessionComposerState,
    preparedAction: DirectSessionComposerPreparedAction,
    startedAt: Date = Date()
  ) {
    guard case let .send(request) = preparedAction else {
      state.pendingRecoveredSendContent = nil
      state.pendingRecoveredSendStartedAt = nil
      return
    }

    state.pendingRecoveredSendContent = normalized(request.content)
    state.pendingRecoveredSendStartedAt = startedAt
  }

  static func clear(_ state: inout DirectSessionComposerState) {
    state.pendingRecoveredSendContent = nil
    state.pendingRecoveredSendStartedAt = nil
  }

  static func shouldRecover(
    pendingContent: String?,
    pendingStartedAt: Date?,
    latestUserMessage: TranscriptMessage?
  ) -> Bool {
    guard let pendingContent = normalized(pendingContent),
          let pendingStartedAt,
          let latestUserMessage,
          latestUserMessage.timestamp >= pendingStartedAt,
          normalized(latestUserMessage.content) == pendingContent
    else {
      return false
    }

    return true
  }

  private static func normalized(_ content: String?) -> String? {
    guard let content else { return nil }
    let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }
}
