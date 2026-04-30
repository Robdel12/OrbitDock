import Foundation

enum NewSessionPreferences {
  private static let preferredProviderKey = "newSession.preferredProvider"

  static var preferredProvider: SessionProvider {
    guard let rawValue = UserDefaults.standard.string(forKey: preferredProviderKey),
          let provider = SessionProvider(rawValue: rawValue)
    else {
      return .codex
    }
    return provider
  }

  static func setPreferredProvider(_ provider: SessionProvider) {
    UserDefaults.standard.set(provider.rawValue, forKey: preferredProviderKey)
  }
}
