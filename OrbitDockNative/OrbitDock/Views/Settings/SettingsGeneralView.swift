import SwiftUI

struct GeneralSettingsView: View {
  @State private var openAiNamingModel = SettingsOpenAiNamingModel()

  var body: some View {
    ScrollView {
      VStack(spacing: Spacing.xl) {
        SettingsOpenAiNamingSection(model: openAiNamingModel)
        SettingsDictationSection()
      }
      .padding(Spacing.xl)
    }
  }
}
