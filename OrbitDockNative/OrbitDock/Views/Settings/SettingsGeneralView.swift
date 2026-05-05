import SwiftUI

struct GeneralSettingsView: View {
  var body: some View {
    ScrollView {
      VStack(spacing: Spacing.xl) {
        SettingsLocalNamingSection()
        SettingsDictationSection()
      }
      .padding(.horizontal, Spacing.section)
      .padding(.vertical, Spacing.section)
      .frame(maxWidth: 980, alignment: .leading)
    }
  }
}
