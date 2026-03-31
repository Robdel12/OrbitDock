import SwiftUI

struct GeneralSettingsView: View {
  @State private var openAiNamingModel = SettingsOpenAiNamingModel()

  var body: some View {
    ScrollView {
      VStack(spacing: Spacing.xl) {
        SettingsOpenAiNamingSection(model: openAiNamingModel)
        SettingsDictationSection()
      }
      .padding(.horizontal, Spacing.section)
      .padding(.vertical, Spacing.section)
      .frame(maxWidth: 980, alignment: .leading)
    }
  }
}
