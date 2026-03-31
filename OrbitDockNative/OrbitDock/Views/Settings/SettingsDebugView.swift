import SwiftUI

struct ServersSettingsView: View {
  @Environment(OrbitDockAppRuntime.self) private var appRuntime

  var body: some View {
    ScrollView {
      VStack(spacing: Spacing.xl) {
        ServerSettingsSheet(layoutMode: .embedded)

        ServerUpdatesSettingsView()

        SettingsSection(title: "DEMO MODE", icon: "sparkles.rectangle.stack") {
          HStack {
            VStack(alignment: .leading, spacing: Spacing.xs) {
              Text("Explore with sample data")
                .font(.system(size: TypeScale.body))
              Text("Read-only demo with seeded sessions and dashboard data.")
                .font(.system(size: TypeScale.meta))
                .foregroundStyle(Color.textTertiary)
            }

            Spacer()

            if appRuntime.isDemoModeEnabled {
              Button("Exit Demo") {
                appRuntime.exitDemoMode()
              }
              .buttonStyle(.bordered)
            } else {
              Button("Enter Demo") {
                appRuntime.enterDemoMode()
              }
              .buttonStyle(.borderedProminent)
              .tint(Color.accent)
            }
          }
        }
      }
      .padding(.horizontal, Spacing.section)
      .padding(.vertical, Spacing.section)
      .frame(maxWidth: 980, alignment: .leading)
    }
  }
}
