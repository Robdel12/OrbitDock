import SwiftUI

struct GeneralSettingsView: View {
  #if os(macOS)
    let appUpdater: AppUpdater?
  #endif
  @State private var openAiNamingModel = SettingsOpenAiNamingModel()

  #if os(macOS)
    init(appUpdater: AppUpdater? = nil) {
      self.appUpdater = appUpdater
    }
  #endif

  var body: some View {
    ScrollView {
      VStack(spacing: Spacing.xl) {
        #if os(macOS)
          if let appUpdater {
            SettingsUpdateChannelSection(appUpdater: appUpdater)
          }
        #endif
        SettingsEditorPreferencesSection()
        SettingsOpenAiNamingSection(model: openAiNamingModel)
        SettingsDictationSection()
      }
      .padding(Spacing.xl)
    }
  }
}
