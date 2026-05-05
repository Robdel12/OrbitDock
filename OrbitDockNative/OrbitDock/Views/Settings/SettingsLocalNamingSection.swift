import SwiftUI

struct SettingsLocalNamingSection: View {
  private var availability: LocalNamingAvailability {
    LocalNamingAvailabilityResolver.current
  }

  private var presentation: SettingsLocalNamingPresentation {
    SettingsGeneralPlanning.localNamingPresentation(availability: availability)
  }

  var body: some View {
    SettingsSection(title: "SESSION NAMING", icon: "text.bubble") {
      VStack(alignment: .leading, spacing: Spacing.lg_) {
        HStack(spacing: Spacing.sm) {
          Image(systemName: presentation.iconName)
            .foregroundStyle(availability == .available ? Color.accent : Color.statusPermission)
          Text(presentation.title)
            .font(.system(size: TypeScale.body))
          Spacer()
          if presentation.showsOnDeviceBadge {
            Text("On Device")
              .font(.system(size: TypeScale.meta, weight: .medium))
              .foregroundStyle(Color.textTertiary)
              .padding(.horizontal, Spacing.sm)
              .padding(.vertical, Spacing.xxs)
              .background(Color.surfaceHover, in: Capsule())
          }
        }

        Text(presentation.statusText)
          .font(.system(size: TypeScale.caption, weight: .medium))
          .foregroundStyle(availability == .available ? Color.feedbackPositive : Color.statusPermission)

        Divider()
          .foregroundStyle(Color.panelBorder)

        Text(presentation.description)
          .font(.system(size: TypeScale.meta))
          .foregroundStyle(Color.textTertiary)
      }
    }
  }
}
