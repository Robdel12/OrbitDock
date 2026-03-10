import SwiftUI

struct GeneralSettingsView: View {
  @State private var openAiNamingModel = SettingsOpenAiNamingModel()

  var body: some View {
    ScrollView {
      VStack(spacing: Spacing.xl) {
        SettingsEditorPreferencesSection()
        SettingsOpenAiNamingSection(model: openAiNamingModel)
        SettingsDictationSection()
      }
      .padding(Spacing.xl)
    }
  }
}
