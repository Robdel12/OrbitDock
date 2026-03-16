import Foundation

enum SettingsOpenAiKeyStatus: Equatable {
  case checking
  case configured
  case notConfigured
}

struct SettingsOpenAiNamingPresentation: Equatable {
  let statusIcon: String?
  let statusText: String
  let statusTone: SettingsSectionTone
  let showsProgress: Bool
  let showsEncryptedBadge: Bool
  let introCopy: String
  let showsStoredKey: Bool
  let showsSavedMessage: Bool
}

struct SettingsDictationPresentation: Equatable {
  let title: String
  let description: String
  let iconName: String
  let showsLiveBadge: Bool
}

enum SettingsSectionTone: Equatable {
  case neutral
  case positive
  case warning
}

enum SettingsGeneralPlanning {
  static func openAiNamingPresentation(
    status: SettingsOpenAiKeyStatus,
    isReplacingKey: Bool,
    keySaved: Bool
  ) -> SettingsOpenAiNamingPresentation {
    let introCopy = isReplacingKey
      ? "Enter a new key to replace the existing one."
      : "OpenAI API key for auto-naming sessions from first prompts."

    switch status {
      case .checking:
        return SettingsOpenAiNamingPresentation(
          statusIcon: nil,
          statusText: "Checking...",
          statusTone: .neutral,
          showsProgress: true,
          showsEncryptedBadge: false,
          introCopy: introCopy,
          showsStoredKey: false,
          showsSavedMessage: false
        )
      case .configured:
        return SettingsOpenAiNamingPresentation(
          statusIcon: "checkmark.circle.fill",
          statusText: "API key configured",
          statusTone: .positive,
          showsProgress: false,
          showsEncryptedBadge: true,
          introCopy: introCopy,
          showsStoredKey: !isReplacingKey,
          showsSavedMessage: keySaved
        )
      case .notConfigured:
        return SettingsOpenAiNamingPresentation(
          statusIcon: "exclamationmark.circle.fill",
          statusText: "No API key set",
          statusTone: .warning,
          showsProgress: false,
          showsEncryptedBadge: false,
          introCopy: introCopy,
          showsStoredKey: false,
          showsSavedMessage: keySaved
        )
    }
  }

  static func dictationPresentation(
    availability: LocalDictationAvailability
  ) -> SettingsDictationPresentation {
    switch availability {
      case .available:
        SettingsDictationPresentation(
          title: "Apple Speech",
          description: "Dictation updates the composer live as you speak and stays fully on-device.",
          iconName: "apple.logo",
          showsLiveBadge: true
        )
      case .unavailable:
        SettingsDictationPresentation(
          title: "Dictation unavailable",
          description: "Dictation requires iOS 26 or macOS 26 because OrbitDock now uses Apple's new Speech framework directly.",
          iconName: "xmark.circle.fill",
          showsLiveBadge: false
        )
    }
  }
}
