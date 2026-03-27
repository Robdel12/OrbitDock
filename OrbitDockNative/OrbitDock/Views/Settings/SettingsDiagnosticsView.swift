import SwiftUI

struct DiagnosticsSettingsView: View {
  var body: some View {
    ScrollView {
      VStack(spacing: Spacing.xl) {
        SettingsSection(title: "DIAGNOSTICS", icon: "stethoscope") {
          VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Server logs, database files, and hook state are owned by the server and CLI.")
              .font(.system(size: TypeScale.body))
              .foregroundStyle(Color.textSecondary)

            Text(
              "Use the server's diagnostics and admin flows to inspect runtime state. The native client no longer treats those filesystem paths as app-owned resources."
            )
            .font(.system(size: TypeScale.meta))
            .foregroundStyle(Color.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .padding(Spacing.xl)
    }
  }
}
