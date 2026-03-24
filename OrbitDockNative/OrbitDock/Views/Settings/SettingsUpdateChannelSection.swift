import SwiftUI

#if os(macOS)
  struct SettingsUpdateChannelSection: View {
    @Bindable var appUpdater: AppUpdater

    var body: some View {
      SettingsSection(title: "UPDATES", icon: "arrow.triangle.2.circlepath") {
        VStack(alignment: .leading, spacing: Spacing.lg_) {
          VStack(alignment: .leading, spacing: Spacing.sm_) {
            HStack {
              Text("Update Channel")
                .font(.system(size: TypeScale.body))

              Spacer()

              Picker("", selection: $appUpdater.selectedChannel) {
                ForEach(UpdateChannel.allCases) { channel in
                  Text(channel.displayName).tag(channel)
                }
              }
              .pickerStyle(.menu)
              .frame(width: 140)
              .tint(Color.accent)
            }

            Text(appUpdater.selectedChannel.description)
              .font(.system(size: TypeScale.meta))
              .foregroundStyle(Color.textTertiary)
          }

          if appUpdater.selectedChannel != .stable {
            Divider()
              .foregroundStyle(Color.panelBorder)

            HStack(spacing: Spacing.sm) {
              Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Color.statusPermission)
              Text(
                "Non-stable channels may include incomplete features or breaking changes."
              )
              .font(.system(size: TypeScale.meta))
              .foregroundStyle(Color.textTertiary)
            }
          }
        }
      }
    }
  }
#endif
