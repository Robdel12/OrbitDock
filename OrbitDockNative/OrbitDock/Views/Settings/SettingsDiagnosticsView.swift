import SwiftUI

struct DiagnosticsSettingsView: View {
  var body: some View {
    ScrollView {
      VStack(spacing: Spacing.xl) {
        SettingsSection(title: "LOGS", icon: "doc.text") {
          VStack(alignment: .leading, spacing: Spacing.md) {
            diagnosticsPathRow(
              label: "Codex Log",
              path: "~/.orbitdock/logs/codex.log"
            ) {
              reveal(PlatformPaths.orbitDockLogsDirectory)
            }

            diagnosticsPathRow(
              label: "Server Log",
              path: "~/.orbitdock/logs/server.log"
            ) {
              reveal(PlatformPaths.orbitDockLogsDirectory)
            }

            diagnosticsPathRow(
              label: "CLI Log",
              path: "~/.orbitdock/cli.log"
            ) {
              reveal(PlatformPaths.orbitDockBaseDirectory)
            }
          }
        }

        SettingsSection(title: "DATABASE", icon: "cylinder") {
          diagnosticsPathRow(
            label: "OrbitDock Database",
            path: "~/.orbitdock/orbitdock.db"
          ) {
            reveal(PlatformPaths.orbitDockBaseDirectory)
          }
        }
      }
      .padding(Spacing.xl)
    }
  }

  private func diagnosticsPathRow(label: String, path: String, action: @escaping () -> Void) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: Spacing.xs) {
        Text(label)
          .font(.system(size: TypeScale.body))
        Text(path)
          .font(.system(size: TypeScale.meta).monospaced())
          .foregroundStyle(Color.textTertiary)
      }

      Spacer()

      Button("Open in Finder", action: action)
        .buttonStyle(.bordered)
    }
  }

  private func reveal(_ url: URL) {
    _ = Platform.services.revealInFileBrowser(url.path)
  }
}
