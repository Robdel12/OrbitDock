import Foundation

struct SettingsLocalNamingPresentation: Equatable {
  let title: String
  let description: String
  let iconName: String
  let statusText: String
  let showsOnDeviceBadge: Bool
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
  static func localNamingPresentation(
    availability: LocalNamingAvailability
  ) -> SettingsLocalNamingPresentation {
    switch availability {
      case .available:
        SettingsLocalNamingPresentation(
          title: "Apple Foundation Models",
          description: "OrbitDock names new sessions on-device from the first real prompt. Restored sessions keep their saved title state, and anything without a generated title falls back to the prompt until you rename it.",
          iconName: "apple.logo",
          statusText: "On-device naming available",
          showsOnDeviceBadge: true
        )
      case .unavailable:
        SettingsLocalNamingPresentation(
          title: "Foundation Models unavailable",
          description: "Automatic session naming requires Apple's Foundation Models on macOS 26 or iOS 26. When unavailable, OrbitDock simply keeps the saved title or shows the first prompt until you rename the session yourself.",
          iconName: "xmark.circle.fill",
          statusText: "Using saved titles and prompt fallback",
          showsOnDeviceBadge: false
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
