import SwiftUI

struct SettingsDictationSection: View {
  @AppStorage("localDictationEnabled") private var localDictationEnabled = true

  private var availability: LocalDictationAvailability {
    LocalDictationAvailabilityResolver.current
  }

  private var presentation: SettingsDictationPresentation {
    SettingsGeneralPlanning.dictationPresentation(availability: availability)
  }

  var body: some View {
    SettingsSection(title: "LOCAL DICTATION", icon: "waveform.badge.mic") {
      VStack(alignment: .leading, spacing: Spacing.lg_) {
        VStack(alignment: .leading, spacing: Spacing.sm_) {
          Toggle(isOn: $localDictationEnabled) {
            Text("Enable Dictation")
              .font(.system(size: TypeScale.body))
          }
          .toggleStyle(.switch)
          .tint(Color.accent)
          .disabled(availability == .unavailable)

          Text("OrbitDock uses Apple's on-device Speech framework for live dictation on iOS 26 and macOS 26. The system may install speech assets the first time you use it.")
            .font(.system(size: TypeScale.meta))
            .foregroundStyle(Color.textTertiary)
        }

        Divider()
          .foregroundStyle(Color.panelBorder)

        HStack(spacing: Spacing.sm) {
          Image(systemName: presentation.iconName)
            .foregroundStyle(availability == .available ? Color.accent : Color.statusPermission)
          Text(presentation.title)
            .font(.system(size: TypeScale.body))
          Spacer()
          if presentation.showsLiveBadge {
            Text("Live")
              .font(.system(size: TypeScale.meta, weight: .medium))
              .foregroundStyle(Color.textTertiary)
              .padding(.horizontal, Spacing.sm)
              .padding(.vertical, Spacing.xxs)
              .background(Color.surfaceHover, in: Capsule())
          }
        }

        Text(presentation.description)
          .font(.system(size: TypeScale.meta))
          .foregroundStyle(Color.textTertiary)
      }
    }
  }
}
