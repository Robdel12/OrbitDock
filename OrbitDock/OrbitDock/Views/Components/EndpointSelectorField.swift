import SwiftUI

struct EndpointSelectorField: View {
  let endpoints: [ServerEndpoint]
  let statusByEndpointId: [UUID: ConnectionStatus]
  let serverPrimaryByEndpointId: [UUID: Bool]
  @Binding var selectedEndpointId: UUID
  var onReconnect: ((UUID) -> Void)? = nil

  private var selectedStatus: ConnectionStatus {
    statusByEndpointId[selectedEndpointId] ?? .disconnected
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: "network")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Color.textTertiary)
        Text("Server")
          .font(.system(size: TypeScale.body, weight: .medium))
          .foregroundStyle(Color.textSecondary)

        Spacer()

        Picker("Server", selection: $selectedEndpointId) {
          ForEach(endpoints) { endpoint in
            Text(endpointLabel(endpoint))
              .tag(endpoint.id)
          }
        }
        .pickerStyle(.menu)
        .labelsHidden()
      }

      HStack(spacing: 6) {
        Circle()
          .fill(statusColor(for: selectedStatus))
          .frame(width: 7, height: 7)
        Text(statusLabel(for: selectedStatus))
          .font(.system(size: TypeScale.caption, weight: .semibold))
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

  private func endpointLabel(_ endpoint: ServerEndpoint) -> String {
    let isServerPrimary = serverPrimaryByEndpointId[endpoint.id] == true
    if endpoint.isDefault && isServerPrimary {
      return "\(endpoint.name) (Control Plane, Server Primary)"
    }
    if endpoint.isDefault {
      return "\(endpoint.name) (Control Plane)"
    }
    if isServerPrimary {
      return "\(endpoint.name) (Server Primary)"
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
