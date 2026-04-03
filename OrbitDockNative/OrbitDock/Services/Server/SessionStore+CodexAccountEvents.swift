import Foundation

@MainActor
extension SessionStore {
  func applyCodexAccountStatus(_ status: ServerCodexAccountStatus) {
    codexAccountStatus = status
  }

  func applyCodexAuthError(_ message: String) {
    codexAuthError = message
  }

  func routeCodexAccountEvent(_ event: ServerEvent) -> Bool {
    switch event {
      case let .codexAccountStatus(status):
        applyCodexAccountStatus(status)
        return true
      case let .codexAccountUpdated(status):
        applyCodexAccountStatus(status)
        return true
      case .codexLoginChatgptStarted(_, _),
           .codexLoginChatgptCompleted(_, _, _),
           .codexLoginChatgptCanceled(_, _):
        return true
      default:
        return false
    }
  }
}
