//
//  ServerSettingsSheet.swift
//  OrbitDock
//
//  Multi-endpoint server configuration and status.
//

import os.log
import SwiftUI

private let serverSettingsLogger = Logger(subsystem: "com.orbitdock", category: "server-settings")

struct ServerSettingsSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry
  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  #endif

  @State private var endpoints: [ServerEndpoint]
  @State private var showEditor = false
  @State private var editingEndpointId: UUID?
  @State private var draft = ServerEndpointEditorDraft(
    name: "",
    hostInput: "",
    isEnabled: true,
    isDefault: false,
    authToken: ""
  )
  @State private var editorError: String?
  @State private var endpointPendingDelete: ServerEndpoint?
  private let endpointSettings: ServerEndpointSettingsClient

  @MainActor
  init(endpointSettings: ServerEndpointSettingsClient? = nil) {
    let resolvedEndpointSettings = endpointSettings ?? .live()
    self.endpointSettings = resolvedEndpointSettings
    _endpoints = State(initialValue: resolvedEndpointSettings.endpoints())
  }

  private var orderedEndpoints: [ServerEndpoint] {
    ServerSettingsSheetPlanner.orderedEndpoints(endpoints)
  }

  // MARK: - Body

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.lg) {
          ForEach(orderedEndpoints) { endpoint in
            endpointCard(endpoint)
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

  // MARK: - Endpoint Card (flat, no expand/collapse)

  private func endpointCard(_ endpoint: ServerEndpoint) -> some View {
    let endpointStatus = status(for: endpoint)
    let isPrimary = runtimeRegistry.primaryEndpointId == endpoint.id
    let isServerPrimary = runtimeRegistry.serverPrimaryByEndpointId[endpoint.id] == true
    let isConnected = endpointStatus == .connected
    let authFailure = isAuthFailure(endpointStatus)
    let endpointStatusColor = statusColor(for: endpointStatus)

    return HStack(alignment: .top, spacing: 0) {
      // Left edge bar with glow
      UnevenRoundedRectangle(
        topLeadingRadius: Radius.lg,
        bottomLeadingRadius: Radius.lg,
        bottomTrailingRadius: 0,
        topTrailingRadius: 0
      )
      .fill(endpointStatusColor)
      .frame(width: EdgeBar.width)
      .themeShadow(Shadow.glow(
        color: isConnected ? endpointStatusColor : .clear,
        intensity: 0.3
      ))

      VStack(alignment: .leading, spacing: Spacing.sm) {
        // Row 1: Status dot + Name + Primary badge + Connection button + Toggle
        HStack(spacing: Spacing.sm) {
          // Status dot with glow
          Circle()
            .fill(endpointStatusColor)
            .frame(width: 7, height: 7)
            .shadow(color: isConnected ? endpointStatusColor.opacity(0.4) : .clear, radius: 4)

          Text(endpoint.name)
            .font(.system(size: TypeScale.title, weight: .semibold))
            .foregroundStyle(endpoint.isEnabled ? Color.textPrimary : Color.textTertiary)

          // Status text
          Text(statusLabel(for: endpointStatus))
            .font(.system(size: TypeScale.caption, weight: .medium))
            .foregroundStyle(endpointStatusColor)

          if isPrimary {
            HStack(spacing: Spacing.gap) {
              Image(systemName: "crown.fill")
                .font(.system(size: 8))
              Text("Primary")
                .font(.system(size: TypeScale.micro, weight: .bold))
            }
            .foregroundStyle(Color.accent)
            .padding(.horizontal, Spacing.sm_)
            .padding(.vertical, Spacing.xxs)
            .background(Color.accent.opacity(OpacityTier.light), in: Capsule())
          }

          Spacer(minLength: Spacing.sm)

          // Connection action button
          if let action = connectionAction(for: endpointStatus), endpoint.isEnabled {
            Button {
              action.handler(endpoint.id)
            } label: {
              Image(systemName: connectionIcon(for: endpointStatus))
                .font(.system(size: IconScale.lg, weight: .semibold))
                .foregroundStyle(Color.accent)
                .frame(width: 28, height: 28)
                .background(Color.accent.opacity(OpacityTier.subtle), in: Circle())
            }
            .buttonStyle(.plain)
          }

          // Enable toggle
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
        }

        // Row 2: URL + role tags
        HStack(spacing: Spacing.sm) {
          Text(endpoint.wsURL.absoluteString)
            .font(.system(size: TypeScale.caption, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)
            .textSelection(.enabled)

          if isServerPrimary {
            Text("Server Primary")
              .font(.system(size: TypeScale.caption, weight: .medium))
              .foregroundStyle(Color.textTertiary)
          }

          if let claimsText = claimingDevicesDescription(for: endpoint) {
            Text(claimsText)
              .font(.system(size: TypeScale.caption, weight: .medium))
              .foregroundStyle(Color.textTertiary)
          }
        }

        // Row 3: Auth failure banner (conditional)
        if authFailure {
          HStack(spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(Color.statusPermission)
              .font(.system(size: IconScale.lg))
            VStack(alignment: .leading, spacing: Spacing.xxs) {
              Text("Authentication failed")
                .font(.system(size: TypeScale.body, weight: .semibold))
                .foregroundStyle(Color.statusPermission)
              Text("Update the auth token for this server.")
                .font(.system(size: TypeScale.caption))
                .foregroundStyle(Color.textSecondary)
            }
          }
          .padding(Spacing.md)
          .background(
            Color.statusPermission.opacity(OpacityTier.light),
            in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
          )
          .overlay(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
              .stroke(Color.statusPermission.opacity(OpacityTier.subtle), lineWidth: 1)
          )
        }

        // Row 4: Action pills (always visible)
        HStack(spacing: Spacing.sm) {
          actionPill("Edit", icon: "pencil", color: Color.textSecondary) {
            beginEditing(endpoint)
          }

          if !isPrimary, endpoint.isEnabled {
            actionPill("Set Primary", icon: "crown", color: Color.accent) {
              setDefaultEndpoint(endpoint.id)
            }
          }

          if let roleAction = serverRoleAction(for: endpoint, status: endpointStatus) {
            actionPill(roleAction.label, icon: "server.rack", color: Color.textSecondary) {
              roleAction.handler(endpoint.id)
            }
          }

          actionPill("Remove", icon: "trash", color: Color.statusPermission) {
            endpointPendingDelete = endpoint
          }
        }
      }
      .padding(.horizontal, Spacing.lg)
      .padding(.vertical, Spacing.md)
    }
    .background(
      Color.backgroundSecondary,
      in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .stroke(
          authFailure
            ? Color.statusPermission.opacity(OpacityTier.medium)
            : Color.panelBorder,
          lineWidth: 1
        )
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
      .padding(.vertical, Spacing.sm_)
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
        Image(systemName: "plus.circle.fill")
          .font(.system(size: IconScale.xxl))
        Text("Add Endpoint")
          .font(.system(size: TypeScale.body, weight: .semibold))
      }
      .foregroundStyle(Color.accent)
      .frame(maxWidth: .infinity)
      .padding(.vertical, Spacing.lg)
      .background(
        Color.accent.opacity(OpacityTier.subtle),
        in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
          .stroke(Color.accent.opacity(OpacityTier.light), lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
  }

  // MARK: - Endpoint Editor Sheet

  private var endpointEditorSheet: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          // Single card with terminal-field style
          VStack(alignment: .leading, spacing: 0) {
            terminalField(icon: "tag", "Name", $draft.name)

            accentDivider

            terminalField(icon: "globe", "Host", $draft.hostInput, monospaced: true)

            accentDivider

            terminalSecureField(icon: "key.fill", "Token", $draft.authToken)

            accentDivider

            toggleRow(icon: "power", "Enabled", $draft.isEnabled)

            accentDivider

            VStack(alignment: .leading, spacing: Spacing.xs) {
              toggleRow(icon: "crown", "Control Plane", $draft.isDefault)
                .disabled(!draft.isEnabled)

              Text("Route usage and dashboard data through this endpoint.")
                .font(.system(size: TypeScale.caption))
                .foregroundStyle(Color.textTertiary)
                .padding(.horizontal, Spacing.lg)
                .padding(.bottom, Spacing.md)
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

          if let editorError {
            HStack(spacing: Spacing.sm) {
              Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: IconScale.lg))
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
            .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }
    }
  }

  // MARK: - Terminal Field Components

  private func terminalField(
    icon: String,
    _ placeholder: String,
    _ text: Binding<String>,
    monospaced: Bool = false
  ) -> some View {
    HStack(spacing: Spacing.md) {
      Image(systemName: icon)
        .font(.system(size: IconScale.lg))
        .foregroundStyle(Color.textTertiary)
        .frame(width: 20, alignment: .center)

      TextField(placeholder, text: text)
        .textFieldStyle(.plain)
        .font(.system(size: TypeScale.body, design: monospaced ? .monospaced : .default))
        .foregroundStyle(Color.textPrimary)
      #if os(iOS)
        .textInputAutocapitalization(monospaced ? .never : .words)
      #endif
        .autocorrectionDisabled()
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.md)
  }

  private func terminalSecureField(
    icon: String,
    _ placeholder: String,
    _ text: Binding<String>
  ) -> some View {
    HStack(spacing: Spacing.md) {
      Image(systemName: icon)
        .font(.system(size: IconScale.lg))
        .foregroundStyle(Color.textTertiary)
        .frame(width: 20, alignment: .center)

      SecureField(placeholder, text: text)
        .textFieldStyle(.plain)
        .font(.system(size: TypeScale.body, design: .monospaced))
        .foregroundStyle(Color.textPrimary)
      #if os(iOS)
        .textInputAutocapitalization(.never)
      #endif
        .autocorrectionDisabled()
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.md)
  }

  private func toggleRow(
    icon: String,
    _ label: String,
    _ isOn: Binding<Bool>
  ) -> some View {
    HStack(spacing: Spacing.md) {
      Image(systemName: icon)
        .font(.system(size: IconScale.lg))
        .foregroundStyle(Color.textTertiary)
        .frame(width: 20, alignment: .center)

      Text(label)
        .font(.system(size: TypeScale.body))
        .foregroundStyle(Color.textSecondary)

      Spacer()

      Toggle(isOn: isOn) {
        EmptyView()
      }
      .toggleStyle(.switch)
      .tint(Color.accent)
      .labelsHidden()
      .fixedSize()
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.md)
  }

  private var accentDivider: some View {
    Divider()
      .overlay(Color.accent.opacity(OpacityTier.light))
  }

  // MARK: - Helpers

  private func status(for endpoint: ServerEndpoint) -> ConnectionStatus {
    if !endpoint.isEnabled {
      return .disconnected
    }

    return runtimeRegistry.displayConnectionStatus(for: endpoint.id)
  }

  private func claimingDevicesDescription(for endpoint: ServerEndpoint) -> String? {
    guard let claims = runtimeRegistry.serverPrimaryClaimsByEndpointId[endpoint.id], !claims.isEmpty else {
      return nil
    }
    let names = claims.map(\.deviceName).joined(separator: ", ")
    return "Claimed as control plane by: \(names)"
  }

  private func isAuthFailure(_ status: ConnectionStatus) -> Bool {
    guard case let .failed(message) = status else { return false }
    let lowered = message.lowercased()
    return lowered.contains("401") || lowered.contains("unauthorized") || lowered.contains("auth")
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
    draft = ServerSettingsSheetPlanner.addDraft(existingEndpoints: endpoints)
    editorError = nil
    showEditor = true
  }

  private func beginEditing(_ endpoint: ServerEndpoint) {
    editingEndpointId = endpoint.id
    draft = ServerSettingsSheetPlanner.editDraft(
      endpoint: endpoint,
      hostInput: endpointSettings.hostInput(endpoint.wsURL) ?? endpoint.wsURL.host ?? ""
    )
    editorError = nil
    showEditor = true
  }

  private func closeEditor() {
    showEditor = false
    editorError = nil
    draft.authToken = ""
  }

  private func saveEditor() {
    switch ServerSettingsSheetPlanner.save(
      currentEndpoints: endpoints,
      editingEndpointID: editingEndpointId,
      draft: draft,
      defaultPort: endpointSettings.defaultPort,
      buildURL: endpointSettings.buildURL
    ) {
      case let .success(updated):
        persistEndpoints(updated)
        closeEditor()
        if let saved = updated.first(where: { $0.id == editingEndpointId }) ?? updated.last {
          serverSettingsLogger.info("Saved endpoint: \(saved.name, privacy: .public)")
        }
      case let .failure(error):
        editorError = error.message
    }
  }

  private func removeEndpoint(_ endpoint: ServerEndpoint) {
    endpointPendingDelete = nil
    let updated = ServerSettingsSheetPlanner.removedEndpoints(
      currentEndpoints: endpoints,
      removing: endpoint
    )
    persistEndpoints(updated)
    serverSettingsLogger.info("Removed endpoint: \(endpoint.name, privacy: .public)")
  }

  private func setDefaultEndpoint(_ endpointId: UUID) {
    let updated = ServerSettingsSheetPlanner.defaultedEndpoints(
      currentEndpoints: endpoints,
      endpointID: endpointId
    )
    persistEndpoints(updated)
  }

  private func updateEndpointEnabled(_ endpointId: UUID, isEnabled: Bool) {
    let updated = ServerSettingsSheetPlanner.enabledEndpoints(
      currentEndpoints: endpoints,
      endpointID: endpointId,
      isEnabled: isEnabled
    )
    persistEndpoints(updated)
  }

  private func persistEndpoints(_ rawEndpoints: [ServerEndpoint]) {
    endpointSettings.saveEndpoints(rawEndpoints)
    runtimeRegistry.configureFromSettings(startEnabled: true)
    refreshFromSettings()
  }

  private func refreshFromSettings() {
    endpoints = endpointSettings.endpoints()
  }
}

#Preview {
  let runtimeRegistry = ServerRuntimeRegistry(
    endpointsProvider: { [] },
    runtimeFactory: { ServerRuntime(endpoint: $0) },
    shouldBootstrapFromSettings: false
  )
  ServerSettingsSheet()
    .environment(runtimeRegistry)
    .preferredColorScheme(.dark)
}
