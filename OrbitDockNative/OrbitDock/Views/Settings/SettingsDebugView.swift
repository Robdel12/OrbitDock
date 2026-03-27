import SwiftUI

struct DebugSettingsView: View {
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry
  @Environment(OrbitDockAppRuntime.self) private var appRuntime
  @State private var showEndpointSettings = false

  private var activeConnectionStatus: ConnectionStatus {
    runtimeRegistry.activeConnectionStatus
  }

  private var endpointHealthSummary: SettingsEndpointHealthSummary {
    let endpointCount = runtimeRegistry.runtimes.count
    let enabledEndpointCount = runtimeRegistry.runtimes.filter(\.endpoint.isEnabled).count
    let connectedEndpointCount = runtimeRegistry.runtimes.filter { runtime in
      let status = runtimeRegistry.displayConnectionStatus(for: runtime.endpoint.id)
      if case .connected = status {
        return true
      }
      return false
    }.count

    return SettingsEndpointHealthSummary.make(
      endpointCount: endpointCount,
      enabledEndpointCount: enabledEndpointCount,
      connectedEndpointCount: connectedEndpointCount
    )
  }

  private var endpointStatusColor: Color {
    switch endpointHealthSummary.tone {
      case .positive:
        Color.feedbackPositive
      case .mixed:
        Color.statusQuestion
      case .warning:
        Color.statusPermission
    }
  }

  var body: some View {
    ScrollView {
      VStack(spacing: Spacing.xl) {
        SettingsSection(title: "ENDPOINTS", icon: "network") {
          HStack(spacing: Spacing.md_) {
            Image(systemName: "antenna.radiowaves.left.and.right")
              .font(.system(size: TypeScale.caption, weight: .semibold))
              .foregroundStyle(endpointStatusColor)

            VStack(alignment: .leading, spacing: Spacing.gap) {
              Text(endpointHealthSummary.detailedText)
                .font(.system(size: TypeScale.body))
                .foregroundStyle(.primary)
              Text("\(endpointHealthSummary.endpointCount) total endpoints configured")
                .font(.system(size: TypeScale.meta, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.textTertiary)
            }

            Spacer()

            Button("Manage Endpoints") {
              showEndpointSettings = true
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accent)
          }

          Text(
            "Choose one control-plane endpoint for this Mac while keeping additional endpoints connected in parallel."
          )
          .font(.system(size: TypeScale.meta))
          .foregroundStyle(Color.textTertiary)
        }

        SettingsSection(title: "CONNECTION", icon: "bolt.horizontal") {
          HStack {
            Circle()
              .fill(connectionColor)
              .frame(width: 8, height: 8)

            Text("WebSocket: \(connectionText)")
              .font(.system(size: TypeScale.body))

            Spacer()
          }
        }

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
      .padding(Spacing.xl)
    }
    .sheet(isPresented: $showEndpointSettings) {
      ServerSettingsSheet()
        .environment(runtimeRegistry)
    }
  }

  private var connectionColor: Color {
    switch activeConnectionStatus {
      case .connected:
        .feedbackPositive
      case .connecting:
        .statusQuestion
      case .disconnected:
        .statusEnded
      case .failed:
        .statusError
    }
  }

  private var connectionText: String {
    switch activeConnectionStatus {
      case .connected:
        "Connected"
      case .connecting:
        "Connecting..."
      case .disconnected:
        "Disconnected"
      case let .failed(reason):
        "Failed: \(reason)"
    }
  }
}
