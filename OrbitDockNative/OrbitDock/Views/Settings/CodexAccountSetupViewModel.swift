import SwiftUI

@MainActor
@Observable
final class CodexAccountSetupViewModel {
  enum AccountState {
    case none
    case apiKey
    case chatgpt(email: String?, planType: String?)
  }

  var endpointStore: ServerEndpointRuntime

  init(endpointStore: ServerEndpointRuntime) {
    self.endpointStore = endpointStore
  }

  var accountState: AccountState {
    switch endpointStore.codexAccountStatus?.account {
      case .apiKey?:
        .apiKey
      case let .chatgpt(email, planType)?:
        .chatgpt(email: email, planType: planType)
      case .none:
        .none
    }
  }

  var authError: String? {
    endpointStore.codexAuthError
  }

  var isSigningIn: Bool {
    endpointStore.codexAccountStatus?.loginInProgress == true
  }

  var hasConnectedAccount: Bool {
    endpointStore.codexAccountStatus?.account != nil
  }

  var accountHeaderIconName: String {
    hasConnectedAccount ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.exclamationmark"
  }

  var accountHeaderIconColor: Color {
    hasConnectedAccount ? Color.feedbackPositive : Color.statusPermission
  }

  func update(endpointStore: ServerEndpointRuntime) {
    self.endpointStore = endpointStore
  }

  func refresh() {
    endpointStore.codexAccountService.refresh()
  }

  func startLogin() {
    endpointStore.codexAccountService.startLogin()
  }

  func cancelLogin() {
    endpointStore.codexAccountService.cancelLogin()
  }

  func logout() {
    endpointStore.codexAccountService.logout()
  }

  func openUsagePage() {
    guard let url = URL(string: "https://chatgpt.com/codex/settings/usage") else { return }
    _ = Platform.services.openURL(url)
  }
}
