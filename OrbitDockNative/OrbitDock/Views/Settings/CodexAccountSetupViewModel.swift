import SwiftUI

@MainActor
@Observable
final class CodexAccountSetupViewModel {
  enum AccountState {
    case none
    case apiKey
    case chatgpt(email: String?, planType: String?)
  }

  var serverState: SessionStore

  init(serverState: SessionStore) {
    self.serverState = serverState
  }

  var accountState: AccountState {
    switch serverState.codexAccountStatus?.account {
      case .apiKey?:
        .apiKey
      case let .chatgpt(email, planType)?:
        .chatgpt(email: email, planType: planType)
      case .none:
        .none
    }
  }

  var authError: String? {
    serverState.codexAuthError
  }

  var isSigningIn: Bool {
    serverState.codexAccountStatus?.loginInProgress == true
  }

  var hasConnectedAccount: Bool {
    serverState.codexAccountStatus?.account != nil
  }

  var accountHeaderIconName: String {
    hasConnectedAccount ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.exclamationmark"
  }

  var accountHeaderIconColor: Color {
    hasConnectedAccount ? Color.feedbackPositive : Color.statusPermission
  }

  func update(serverState: SessionStore) {
    self.serverState = serverState
  }

  func refresh() {
    serverState.codexAccountService.refresh()
  }

  func startLogin() {
    serverState.codexAccountService.startLogin()
  }

  func cancelLogin() {
    serverState.codexAccountService.cancelLogin()
  }

  func logout() {
    serverState.codexAccountService.logout()
  }

  func openUsagePage() {
    guard let url = URL(string: "https://chatgpt.com/codex/settings/usage") else { return }
    _ = Platform.services.openURL(url)
  }
}
