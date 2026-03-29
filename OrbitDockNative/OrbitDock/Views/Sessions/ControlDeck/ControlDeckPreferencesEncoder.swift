import Foundation

enum ControlDeckPreferencesEncoder {
  static func encode(_ preferences: ControlDeckPreferences) -> ServerControlDeckPreferences {
    ServerControlDeckPreferences(
      density: encodeDensity(preferences.density),
      showWhenEmpty: encodeEmptyVisibility(preferences.showWhenEmpty),
      modules: preferences.modules.map { pref in
        ServerControlDeckModulePreference(
          module: encodeModule(pref.module),
          visible: pref.visible
        )
      }
    )
  }

  private static func encodeDensity(_ density: ControlDeckDensity) -> ServerControlDeckDensity {
    switch density {
      case .comfortable: .comfortable
      case .compact: .compact
    }
  }

  private static func encodeEmptyVisibility(_ vis: ControlDeckEmptyVisibility) -> ServerControlDeckEmptyVisibility {
    switch vis {
      case .auto: .auto
      case .always: .always
      case .hidden: .hidden
    }
  }

  private static func encodeModule(_ module: ControlDeckStatusModule) -> ServerControlDeckModule {
    switch module {
      case .connection: .connection
      case .autonomy: .autonomy
      case .approvalMode: .approvalMode
      case .collaborationMode: .collaborationMode
      case .autoReview: .autoReview
      case .tokens: .tokens
      case .model: .model
      case .effort: .effort
      case .branch: .branch
      case .cwd: .cwd
      case .attachments: .attachments
    }
  }
}
