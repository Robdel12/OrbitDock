import SwiftUI

struct EndpointSelectorField: View {
  let endpoints: [ServerEndpoint]
  let statusByEndpointId: [UUID: ConnectionStatus]
  let serverPrimaryByEndpointId: [UUID: Bool]
  @Binding var selectedEndpointId: UUID
  var onReconnect: ((UUID) -> Void)?

  private var selectedEndpoint: ServerEndpoint? {
    endpoints.first(where: { $0.id == selectedEndpointId })
      ?? endpoints.first
  }

  private var hasMultipleEndpoints: Bool {
    endpoints.count > 1
  }

  private var isControlPlaneEndpoint: Bool {
    selectedEndpoint?.isDefault == true
  }

  private var isServerPrimaryEndpoint: Bool {
    serverPrimaryByEndpointId[selectedEndpointId] == true
  }

  private var selectedStatus: ConnectionStatus {
    statusByEndpointId[selectedEndpointId] ?? .disconnected
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack(spacing: Spacing.sm) {
        Image(systemName: "network")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Color.textTertiary)
        Text("Server")
          .font(.system(size: TypeScale.body, weight: .medium))
          .foregroundStyle(Color.textSecondary)

        Spacer()

        if hasMultipleEndpoints {
          Picker("Server", selection: $selectedEndpointId) {
            ForEach(endpoints) { endpoint in
              Text(endpointLabel(endpoint))
                .tag(endpoint.id)
            }
          }
          .pickerStyle(.menu)
          .labelsHidden()
        } else if let selectedEndpoint {
          Text(selectedEndpoint.name)
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(Color.textPrimary)
            .lineLimit(1)
        }
      }

      HStack(spacing: Spacing.xs) {
        if isControlPlaneEndpoint {
          roleBadge(title: "Control Plane", tint: Color.accent)
        }

        if isServerPrimaryEndpoint {
          roleBadge(title: "Server Primary", tint: Color.statusWorking)
        }

        if !hasMultipleEndpoints, !isControlPlaneEndpoint, !isServerPrimaryEndpoint {
          Text("Single endpoint")
            .font(.system(size: TypeScale.micro, weight: .medium))
            .foregroundStyle(Color.textQuaternary)
        }
      }

      HStack(spacing: 6) {
        Circle()
          .fill(statusColor(for: selectedStatus))
          .frame(width: 7, height: 7)
        Text(statusLabel(for: selectedStatus))
          .font(.system(size: TypeScale.caption, weight: .medium))
          .foregroundStyle(Color.textTertiary)

        Spacer()

        if case .connected = selectedStatus {
          EmptyView()
        } else if let onReconnect {
          Button("Connect") {
            onReconnect(selectedEndpointId)
          }
          .buttonStyle(.plain)
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.accent)
        }
      }
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.md)
    .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.lg))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg)
        .stroke(Color.surfaceBorder, lineWidth: 1)
    )
  }

  private func roleBadge(title: String, tint: Color) -> some View {
    Text(title)
      .font(.system(size: TypeScale.micro, weight: .semibold))
      .foregroundStyle(tint)
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, 3)
      .background(tint.opacity(OpacityTier.tint), in: Capsule())
      .overlay(
        Capsule()
          .stroke(tint.opacity(OpacityTier.medium), lineWidth: 1)
      )
  }

  private func endpointLabel(_ endpoint: ServerEndpoint) -> String {
    let isServerPrimary = serverPrimaryByEndpointId[endpoint.id] == true
    if endpoint.isDefault, isServerPrimary {
      return "\(endpoint.name) (CP, Primary)"
    }
    if endpoint.isDefault {
      return "\(endpoint.name) (CP)"
    }
    if isServerPrimary {
      return "\(endpoint.name) (Primary)"
    }
    return endpoint.name
  }

  private func statusColor(for status: ConnectionStatus) -> Color {
    switch status {
      case .connected:
        Color.statusWorking
      case .connecting:
        Color.statusQuestion
      case .disconnected:
        Color.textTertiary
      case .failed:
        Color.statusPermission
    }
  }

  private func statusLabel(for status: ConnectionStatus) -> String {
    switch status {
      case .connected:
        "Connected"
      case .connecting:
        "Connecting"
      case .disconnected:
        "Disconnected"
      case .failed:
        "Failed"
    }
  }
}
