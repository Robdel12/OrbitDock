import Foundation

@MainActor
final class CodexAccountService {
  private unowned let store: SessionStore

  init(store: SessionStore) {
    self.store = store
  }

  func refresh() {
    guard SessionStore.shouldAutoRefreshCodexAccount() else { return }
    Task { [weak self] in
      guard let self else { return }
      await self.performRefresh()
    }
  }

  func startLogin() {
    Task { [weak self] in
      guard let self else { return }
      await self.performStartLogin()
    }
  }

  func cancelLogin() {
    Task { [weak self] in
      guard let self else { return }
      await self.performCancelLogin()
    }
  }

  func logout() {
    Task { [weak self] in
      guard let self else { return }
      await self.performLogout()
    }
  }

  private func performRefresh() async {
    do {
      let status = try await store.clients.usage.readCodexAccount()
      store.applyCodexAccountStatus(status)
    } catch {
      netLog(.warning, cat: .store, "Refresh Codex account failed", data: [
        "error": error.localizedDescription,
      ])
    }
  }

  private func performStartLogin() async {
    do {
      let response = try await store.clients.usage.startCodexLogin()
      if let url = URL(string: response.authUrl) {
        _ = Platform.services.openURL(url)
      }
    } catch {
      store.applyCodexAuthError(error.localizedDescription)
    }
  }

  private func performCancelLogin() async {
    guard let loginId = store.codexAccountStatus?.activeLoginId else { return }
    do {
      try await store.clients.usage.cancelCodexLogin(loginId: loginId)
    } catch {
      netLog(.warning, cat: .store, "Cancel Codex login failed", data: [
        "error": error.localizedDescription,
      ])
    }
  }

  private func performLogout() async {
    do {
      let status = try await store.clients.usage.logoutCodexAccount()
      store.applyCodexAccountStatus(status)
    } catch {
      store.applyCodexAuthError(error.localizedDescription)
    }
  }
}
