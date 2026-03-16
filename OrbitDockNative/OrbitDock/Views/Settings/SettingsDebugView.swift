import SwiftUI

struct DebugSettingsView: View {
  #if os(macOS)
    @Environment(\.serverManager) private var serverManager
  #endif
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry
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

        SettingsSection(title: "SERVER", icon: "server.rack") {
          #if os(macOS)
            HStack {
              Circle()
                .fill(installStateColor)
                .frame(width: 8, height: 8)

              Text(installStateLabel)
                .font(.system(size: TypeScale.body))

              Spacer()

              serverActionButtons
            }

            if let error = serverManager.installError {
              Text(error)
                .font(.system(size: TypeScale.meta))
                .foregroundStyle(Color.statusError)
            }
          #else
            Text("Local server install controls are available on macOS.")
              .font(.system(size: TypeScale.body))
              .foregroundStyle(Color.textSecondary)
          #endif
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

          HStack {
            #if os(macOS)
              VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Binary")
                  .font(.system(size: TypeScale.body))
                Text(serverManager.findServerBinary() ?? "Not found")
                  .font(.system(size: TypeScale.meta).monospaced())
                  .foregroundStyle(Color.textTertiary)
              }

              Spacer()

              Button("Refresh") {
                Task { await serverManager.refreshState() }
              }
              .buttonStyle(.bordered)
            #else
              VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Binary")
                  .font(.system(size: TypeScale.body))
                Text("Managed by the connected server runtime")
                  .font(.system(size: TypeScale.meta).monospaced())
                  .foregroundStyle(Color.textTertiary)
              }
            #endif
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

  private var installStateColor: Color {
    #if os(macOS)
      switch serverManager.installState {
        case .running: .feedbackPositive
        case .installed: .statusReply
        case .remote: .statusQuestion
        case .notConfigured: .statusEnded
        case .unknown: .statusEnded
      }
    #else
      .statusReply
    #endif
  }

  private var installStateLabel: String {
    #if os(macOS)
      switch serverManager.installState {
        case .running: "Server Running"
        case .installed: "Installed (Stopped)"
        case .remote: "Remote Configured"
        case .notConfigured: "Not Configured"
        case .unknown: "Checking..."
      }
    #else
      "Managed by Connected Runtime"
    #endif
  }

  @ViewBuilder
  private var serverActionButtons: some View {
    #if os(macOS)
      switch serverManager.installState {
        case .running:
        HStack(spacing: Spacing.sm) {
          Button("Stop") {
            Task { try? await serverManager.stopService() }
          }
          .buttonStyle(.bordered)

          Button("Restart") {
            Task { try? await serverManager.restartService() }
          }
          .buttonStyle(.bordered)
        }

        case .installed:
        Button("Start") {
          Task {
            try? await serverManager.startService()
            if serverManager.installState == .running {
              runtimeRegistry.startEnabledRuntimes()
            }
          }
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.accent)

        case .notConfigured:
        Button("Install") {
          Task {
            try? await serverManager.install()
            if serverManager.installState == .running {
              runtimeRegistry.startEnabledRuntimes()
            }
          }
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.accent)
        .disabled(serverManager.isInstalling)

        case .remote, .unknown:
        EmptyView()
      }
    #endif
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
