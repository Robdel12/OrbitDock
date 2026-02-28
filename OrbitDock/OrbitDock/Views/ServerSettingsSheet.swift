//
//  ServerSettingsSheet.swift
//  OrbitDock
//
//  Multi-endpoint server configuration and status.
//

import os.log
import SwiftUI

private let logger = Logger(subsystem: "com.orbitdock", category: "server-settings")

struct ServerSettingsSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry
  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  #endif

  @State private var endpoints: [ServerEndpoint] = ServerEndpointSettings.endpoints
  @State private var expandedEndpointId: UUID?
  @State private var showEditor = false
  @State private var editingEndpointId: UUID?
  @State private var draftName = ""
  @State private var draftHostInput = ""
  @State private var draftIsEnabled = true
  @State private var draftIsDefault = false
  @State private var draftIsLocalManaged = false
  @State private var editorError: String?
  @State private var endpointPendingDelete: ServerEndpoint?

  private var orderedEndpoints: [ServerEndpoint] {
    endpoints.sorted { lhs, rhs in
      if lhs.isDefault != rhs.isDefault {
        return lhs.isDefault && !rhs.isDefault
      }
      if lhs.isEnabled != rhs.isEnabled {
        return lhs.isEnabled && !rhs.isEnabled
      }
      if lhs.isLocalManaged != rhs.isLocalManaged {
        return lhs.isLocalManaged && !rhs.isLocalManaged
      }
      let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
      if nameOrder != .orderedSame {
        return nameOrder == .orderedAscending
      }
      return lhs.id.uuidString < rhs.id.uuidString
    }
  }

  // MARK: - Body

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.lg) {
          ForEach(orderedEndpoints) { endpoint in
            endpointRow(endpoint)
          }

          addEndpointButton
        }
        .padding(Spacing.section)
      }
      .background(Color.backgroundPrimary)
      .navigationTitle("Servers")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Done") {
              dismiss()
            }
            .foregroundStyle(Color.accent)
          }
        }
    }
    .onAppear {
      refreshFromSettings()
    }
    .sheet(isPresented: $showEditor) {
      endpointEditorSheet
    }
    .alert(
      "Remove Endpoint",
      isPresented: Binding(
        get: { endpointPendingDelete != nil },
        set: { newValue in
          if !newValue {
            endpointPendingDelete = nil
          }
        }
      ),
      presenting: endpointPendingDelete
    ) { endpoint in
      Button("Cancel", role: .cancel) {
        endpointPendingDelete = nil
      }
      Button("Remove", role: .destructive) {
        removeEndpoint(endpoint)
      }
    } message: { endpoint in
      Text("Remove \(endpoint.name)? Any active connection to this endpoint will be stopped.")
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
  }

  // MARK: - Endpoint Row

  private func endpointRow(_ endpoint: ServerEndpoint) -> some View {
    let endpointStatus = status(for: endpoint)
    let isExpanded = expandedEndpointId == endpoint.id
    let isPrimary = runtimeRegistry.primaryEndpointId == endpoint.id
    let isServerPrimary = runtimeRegistry.serverPrimaryByEndpointId[endpoint.id] == true

    return HStack(alignment: .top, spacing: 0) {
      // Left accent bar — connection status
      RoundedRectangle(cornerRadius: 2, style: .continuous)
        .fill(statusColor(for: endpointStatus))
        .frame(width: EdgeBar.width)
        .frame(maxHeight: .infinity)
        .shadow(
          color: endpointStatus == .connected ? statusColor(for: endpointStatus).opacity(0.3) : .clear,
          radius: 4
        )

      VStack(alignment: .leading, spacing: 0) {
        // Primary row — name + status + connection action + toggle + chevron
        Button {
          withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            expandedEndpointId = isExpanded ? nil : endpoint.id
          }
        } label: {
          HStack(alignment: .center, spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
              HStack(spacing: Spacing.sm) {
                Text(endpoint.name)
                  .font(.system(size: TypeScale.title, weight: .semibold))
                  .foregroundStyle(endpoint.isEnabled ? Color.textPrimary : Color.textTertiary)
                  .lineLimit(1)

                if isPrimary {
                  HStack(spacing: 3) {
                    Image(systemName: "crown.fill")
                      .font(.system(size: 8))
                    Text("Primary")
                      .font(.system(size: TypeScale.micro, weight: .bold))
                  }
                  .foregroundStyle(Color.accent)
                  .padding(.horizontal, 6)
                  .padding(.vertical, 2)
                  .background(Color.accent.opacity(OpacityTier.light), in: Capsule())
                }
              }

              Text(statusLabel(for: endpointStatus))
                .font(.system(size: TypeScale.caption, weight: .medium))
                .foregroundStyle(statusColor(for: endpointStatus))
                .lineLimit(1)
            }

            Spacer(minLength: Spacing.sm)

            // Inline connection action — always visible when relevant
            if let action = connectionAction(for: endpointStatus), endpoint.isEnabled {
              Button {
                action.handler(endpoint.id)
              } label: {
                Image(systemName: connectionIcon(for: endpointStatus))
                  .font(.system(size: 11, weight: .semibold))
                  .foregroundStyle(Color.accent)
                  .frame(width: 28, height: 28)
                  .background(Color.accent.opacity(OpacityTier.subtle), in: Circle())
              }
              .buttonStyle(.plain)
            }

            Toggle(
              isOn: Binding(
                get: { endpoint.isEnabled },
                set: { isEnabled in
                  updateEndpointEnabled(endpoint.id, isEnabled: isEnabled)
                }
              )
            ) {
              EmptyView()
            }
            .toggleStyle(.switch)
            .tint(Color.accent)
            .labelsHidden()
            .fixedSize()

            Image(systemName: "chevron.right")
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(Color.textQuaternary)
              .rotationEffect(.degrees(isExpanded ? 90 : 0))
          }
          .padding(.horizontal, Spacing.lg)
          .padding(.vertical, Spacing.md)
        }
        .buttonStyle(.plain)

        // Expanded section — secondary actions + details
        if isExpanded {
          VStack(alignment: .leading, spacing: Spacing.md) {
            // Detail line: URL + role tags
            VStack(alignment: .leading, spacing: Spacing.xs) {
              Text(endpoint.wsURL.absoluteString)
                .font(.system(size: TypeScale.caption, design: .monospaced))
                .foregroundStyle(Color.textQuaternary)
                .lineLimit(1)
                .textSelection(.enabled)

              HStack(spacing: Spacing.sm) {
                if isServerPrimary {
                  Text("Server Primary")
                    .foregroundStyle(Color.textTertiary)
                }
                if endpoint.isLocalManaged {
                  Text("Local")
                    .foregroundStyle(Color.textTertiary)
                }
                if let claimsText = claimingDevicesDescription(for: endpoint) {
                  Text(claimsText)
                    .foregroundStyle(Color.textTertiary)
                }
              }
              .font(.system(size: TypeScale.caption, weight: .medium))
            }

            // Secondary action buttons
            HStack(spacing: Spacing.sm) {
              if !isPrimary, endpoint.isEnabled {
                actionPill("Set as Primary", icon: "crown", color: Color.accent) {
                  setDefaultEndpoint(endpoint.id)
                }
              }

              if let roleAction = serverRoleAction(for: endpoint, status: endpointStatus) {
                actionPill(roleAction.label, icon: "server.rack", color: Color.textSecondary) {
                  roleAction.handler(endpoint.id)
                }
              }
            }

            // Edit / Remove row
            HStack(spacing: Spacing.lg) {
              Button {
                beginEditing(endpoint)
              } label: {
                HStack(spacing: Spacing.xs) {
                  Image(systemName: "pencil")
                    .font(.system(size: 10, weight: .semibold))
                  Text("Edit")
                    .font(.system(size: TypeScale.caption, weight: .medium))
                }
                .foregroundStyle(Color.textTertiary)
              }
              .buttonStyle(.plain)

              if !endpoint.isLocalManaged {
                Button {
                  endpointPendingDelete = endpoint
                } label: {
                  HStack(spacing: Spacing.xs) {
                    Image(systemName: "trash")
                      .font(.system(size: 10, weight: .semibold))
                    Text("Remove")
                      .font(.system(size: TypeScale.caption, weight: .medium))
                  }
                  .foregroundStyle(Color.statusPermission.opacity(0.7))
                }
                .buttonStyle(.plain)
              }
            }
          }
          .padding(.horizontal, Spacing.lg)
          .padding(.bottom, Spacing.lg)
          .transition(.opacity.combined(with: .move(edge: .top)))
        }
      }
    }
    .background(
      Color.backgroundSecondary,
      in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .stroke(Color.panelBorder, lineWidth: 1)
    )
    .clipped()
  }

  // MARK: - Action Pill

  private func actionPill(
    _ label: String,
    icon: String,
    color: Color,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: Spacing.xs) {
        Image(systemName: icon)
          .font(.system(size: 10, weight: .semibold))
        Text(label)
          .font(.system(size: TypeScale.caption, weight: .semibold))
      }
      .foregroundStyle(color)
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, 6)
      .background(color.opacity(OpacityTier.subtle), in: Capsule())
    }
    .buttonStyle(.plain)
  }

  // MARK: - Add Endpoint

  private var addEndpointButton: some View {
    Button {
      beginAddingEndpoint()
    } label: {
      HStack(spacing: Spacing.sm) {
        Image(systemName: "plus.circle")
          .font(.system(size: 14, weight: .medium))
        Text("Add Endpoint")
          .font(.system(size: TypeScale.body, weight: .medium))
      }
      .foregroundStyle(Color.textTertiary)
      .frame(maxWidth: .infinity)
      .padding(.vertical, Spacing.lg)
      .background(
        RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
          .strokeBorder(Color.panelBorder, style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
      )
    }
    .buttonStyle(.plain)
  }

  // MARK: - Endpoint Editor Sheet

  private var endpointEditorSheet: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          // Single card with all fields
          VStack(alignment: .leading, spacing: 0) {
            // Name field
            editorField(label: "Name") {
              TextField("My Server", text: $draftName)
                .textFieldStyle(.plain)
                .font(.system(size: TypeScale.body))
              #if os(iOS)
                .textInputAutocapitalization(.words)
              #endif
            }

            Divider()
              .overlay(Color.panelBorder)

            // Host field
            editorField(label: "Host") {
              TextField("10.0.0.5 or 10.0.0.5:4100", text: $draftHostInput)
                .textFieldStyle(.plain)
                .font(.system(size: TypeScale.body, design: .monospaced))
              #if os(iOS)
                .textInputAutocapitalization(.never)
              #endif
                .autocorrectionDisabled()
                .disabled(draftIsLocalManaged)
            }

            if draftIsLocalManaged {
              Text("Host is managed automatically for local endpoints.")
                .font(.system(size: TypeScale.caption))
                .foregroundStyle(Color.textTertiary)
                .padding(.horizontal, Spacing.lg)
                .padding(.bottom, Spacing.md)
                .padding(.top, -Spacing.xs)
            }

            Divider()
              .overlay(Color.panelBorder)

            // Enabled toggle
            editorField(label: "Enabled") {
              Spacer()
              Toggle(isOn: $draftIsEnabled) {
                EmptyView()
              }
              .toggleStyle(.switch)
              .tint(Color.accent)
              .labelsHidden()
              .fixedSize()
            }

            Divider()
              .overlay(Color.panelBorder)

            // Control-plane toggle
            VStack(alignment: .leading, spacing: Spacing.xs) {
              editorField(label: "Control Plane") {
                Spacer()
                Toggle(isOn: $draftIsDefault) {
                  EmptyView()
                }
                .toggleStyle(.switch)
                .tint(Color.accent)
                .labelsHidden()
                .fixedSize()
                .disabled(!draftIsEnabled)
              }

              Text("Route usage and dashboard data through this endpoint.")
                .font(.system(size: TypeScale.caption))
                .foregroundStyle(Color.textTertiary)
                .padding(.horizontal, Spacing.lg)
                .padding(.bottom, Spacing.md)
            }
          }
          .background(Color.backgroundSecondary, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
              .stroke(Color.panelBorder, lineWidth: 1)
          )

          if let editorError {
            HStack(spacing: Spacing.sm) {
              Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.statusPermission)
              Text(editorError)
                .foregroundStyle(Color.statusPermission)
                .font(.system(size: TypeScale.caption, weight: .medium))
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
              Color.statusPermission.opacity(OpacityTier.light),
              in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            )
            .padding(.top, Spacing.lg)
          }
        }
        .padding(Spacing.section)
      }
      .background(Color.backgroundPrimary)
      .navigationTitle(editingEndpointId == nil ? "Add Endpoint" : "Edit Endpoint")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
              closeEditor()
            }
            .foregroundStyle(Color.textSecondary)
          }
          ToolbarItem(placement: .confirmationAction) {
            Button("Save") {
              saveEditor()
            }
            .foregroundStyle(Color.accent)
            .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }
    }
  }

  private func editorField<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
    HStack(spacing: Spacing.md) {
      Text(label)
        .font(.system(size: TypeScale.body, weight: .medium))
        .foregroundStyle(Color.textSecondary)
        .frame(width: 90, alignment: .leading)

      content()
        .foregroundStyle(Color.textPrimary)
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.md)
  }

  // MARK: - Helpers

  private func status(for endpoint: ServerEndpoint) -> ConnectionStatus {
    if !endpoint.isEnabled {
      return .disconnected
    }

    return runtimeRegistry.connectionStatusByEndpointId[endpoint.id]
      ?? runtimeRegistry.runtimesByEndpointId[endpoint.id]?.connection.status
      ?? .disconnected
  }

  private func claimingDevicesDescription(for endpoint: ServerEndpoint) -> String? {
    guard let claims = runtimeRegistry.serverPrimaryClaimsByEndpointId[endpoint.id], !claims.isEmpty else {
      return nil
    }
    let names = claims.map(\.deviceName).joined(separator: ", ")
    return "Claimed as control plane by: \(names)"
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

  private func connectionIcon(for status: ConnectionStatus) -> String {
    switch status {
      case .connected:
        "bolt.slash"
      case .connecting:
        "xmark"
      case .disconnected:
        "bolt"
      case .failed:
        "arrow.clockwise"
    }
  }

  private func connectionAction(for status: ConnectionStatus) -> (label: String, handler: (UUID) -> Void)? {
    switch status {
      case .connected:
        ("Disconnect", { endpointId in
          runtimeRegistry.stop(endpointId: endpointId)
        })
      case .connecting:
        ("Cancel", { endpointId in
          runtimeRegistry.stop(endpointId: endpointId)
        })
      case .disconnected:
        ("Connect", { endpointId in
          runtimeRegistry.reconnect(endpointId: endpointId)
        })
      case .failed:
        ("Reconnect", { endpointId in
          runtimeRegistry.reconnect(endpointId: endpointId)
        })
    }
  }

  private func serverRoleAction(
    for endpoint: ServerEndpoint,
    status: ConnectionStatus
  ) -> (label: String, handler: (UUID) -> Void)? {
    guard endpoint.isEnabled else { return nil }
    guard case .connected = status else { return nil }

    if runtimeRegistry.serverPrimaryByEndpointId[endpoint.id] == true {
      return ("Mark Secondary", { endpointId in
        runtimeRegistry.setServerRole(endpointId: endpointId, isPrimary: false)
      })
    }

    return ("Mark Primary", { endpointId in
      runtimeRegistry.setServerRole(endpointId: endpointId, isPrimary: true)
    })
  }

  // MARK: - State Mutations

  private func beginAddingEndpoint() {
    editingEndpointId = nil
    draftName = ""
    draftHostInput = ""
    draftIsEnabled = true
    draftIsDefault = endpoints.first(where: \.isDefault) == nil
    draftIsLocalManaged = false
    editorError = nil
    showEditor = true
  }

  private func beginEditing(_ endpoint: ServerEndpoint) {
    editingEndpointId = endpoint.id
    draftName = endpoint.name
    draftHostInput = ServerEndpointSettings.hostInput(from: endpoint.wsURL) ?? endpoint.wsURL.host ?? ""
    draftIsEnabled = endpoint.isEnabled
    draftIsDefault = endpoint.isDefault
    draftIsLocalManaged = endpoint.isLocalManaged
    editorError = nil
    showEditor = true
  }

  private func closeEditor() {
    showEditor = false
    editorError = nil
  }

  private func saveEditor() {
    let trimmedName = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else {
      editorError = "Endpoint name is required."
      return
    }

    let endpointId = editingEndpointId ?? UUID()
    let existingEndpoint = endpoints.first(where: { $0.id == endpointId })
    let isLocalManaged = existingEndpoint?.isLocalManaged ?? draftIsLocalManaged

    let resolvedURL: URL
    if isLocalManaged {
      resolvedURL = existingEndpoint?.wsURL ?? ServerEndpoint
        .localDefault(defaultPort: ServerEndpointSettings.defaultPort).wsURL
    } else {
      guard let built = ServerEndpointSettings.buildURL(from: draftHostInput) else {
        editorError = "Enter a valid host (for example 10.0.0.5 or 10.0.0.5:4100)."
        return
      }
      resolvedURL = built
    }

    var updated = endpoints
    let endpoint = ServerEndpoint(
      id: endpointId,
      name: trimmedName,
      wsURL: resolvedURL,
      isLocalManaged: isLocalManaged,
      isEnabled: draftIsEnabled,
      isDefault: draftIsEnabled && draftIsDefault
    )

    if let index = updated.firstIndex(where: { $0.id == endpointId }) {
      updated[index] = endpoint
    } else {
      updated.append(endpoint)
    }

    if endpoint.isDefault {
      for idx in updated.indices {
        updated[idx].isDefault = updated[idx].id == endpoint.id
      }
    }

    persistEndpoints(updated)
    closeEditor()
    logger.info("Saved endpoint: \(endpoint.name, privacy: .public)")
  }

  private func removeEndpoint(_ endpoint: ServerEndpoint) {
    endpointPendingDelete = nil
    guard !endpoint.isLocalManaged else { return }
    let updated = endpoints.filter { $0.id != endpoint.id }
    persistEndpoints(updated)
    logger.info("Removed endpoint: \(endpoint.name, privacy: .public)")
  }

  private func setDefaultEndpoint(_ endpointId: UUID) {
    var updated = endpoints
    guard let index = updated.firstIndex(where: { $0.id == endpointId }) else { return }

    updated[index].isEnabled = true
    for idx in updated.indices {
      updated[idx].isDefault = updated[idx].id == endpointId
    }

    persistEndpoints(updated)
  }

  private func updateEndpointEnabled(_ endpointId: UUID, isEnabled: Bool) {
    var updated = endpoints
    guard let index = updated.firstIndex(where: { $0.id == endpointId }) else { return }

    updated[index].isEnabled = isEnabled
    if !isEnabled {
      updated[index].isDefault = false
    }

    persistEndpoints(updated)
  }

  private func persistEndpoints(_ rawEndpoints: [ServerEndpoint]) {
    ServerEndpointSettings.saveEndpoints(rawEndpoints)
    runtimeRegistry.configureFromSettings(startEnabled: true)
    refreshFromSettings()
  }

  private func refreshFromSettings() {
    endpoints = ServerEndpointSettings.endpoints
  }
}

#Preview {
  ServerSettingsSheet()
    .environment(ServerRuntimeRegistry.shared)
    .preferredColorScheme(.dark)
}
