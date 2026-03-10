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

  @State private var endpoints: [ServerEndpoint]
  @State private var expandedEndpointId: UUID?
  @State private var showEditor = false
  @State private var editingEndpointId: UUID?
  @State private var draft = ServerEndpointEditorDraft(
    name: "",
    hostInput: "",
    isEnabled: true,
    isDefault: false,
    isLocalManaged: false,
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
      RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
        .fill(statusColor(for: endpointStatus))
        .frame(width: EdgeBar.width)
        .frame(maxHeight: .infinity)
        .themeShadow(Shadow.glow(
          color: endpointStatus == .connected ? statusColor(for: endpointStatus) : .clear,
          intensity: 0.3
        ))

      VStack(alignment: .leading, spacing: 0) {
        // Primary row — name + status + connection action + toggle + chevron
        Button {
          withAnimation(Motion.standard) {
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
              TextField("My Server", text: $draft.name)
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
              TextField("10.0.0.5:4000 or https://host.example", text: $draft.hostInput)
                .textFieldStyle(.plain)
                .font(.system(size: TypeScale.body, design: .monospaced))
              #if os(iOS)
                .textInputAutocapitalization(.never)
              #endif
                .autocorrectionDisabled()
                .disabled(draft.isLocalManaged)
            }

            if draft.isLocalManaged {
              Text("Host is managed automatically for local endpoints.")
                .font(.system(size: TypeScale.caption))
                .foregroundStyle(Color.textTertiary)
                .padding(.horizontal, Spacing.lg)
                .padding(.bottom, Spacing.md)
                .padding(.top, -Spacing.xs)
            }

            if !draft.isLocalManaged {
              Divider()
                .overlay(Color.panelBorder)

              // Auth token field
              editorField(label: "Auth Token") {
                SecureField("Paste token", text: $draft.authToken)
                  .textFieldStyle(.plain)
                  .font(.system(size: TypeScale.body, design: .monospaced))
                #if os(iOS)
                  .textInputAutocapitalization(.never)
                #endif
                  .autocorrectionDisabled()
              }
            }

            Divider()
              .overlay(Color.panelBorder)

            // Enabled toggle
            editorField(label: "Enabled") {
              Spacer()
              Toggle(isOn: $draft.isEnabled) {
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
                Toggle(isOn: $draft.isDefault) {
                  EmptyView()
                }
                .toggleStyle(.switch)
                .tint(Color.accent)
                .labelsHidden()
                .fixedSize()
                .disabled(!draft.isEnabled)
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
            .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }
    }
  }

  private func editorField(label: String, @ViewBuilder content: () -> some View) -> some View {
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

    return runtimeRegistry.displayConnectionStatus(for: endpoint.id)
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
          logger.info("Saved endpoint: \(saved.name, privacy: .public)")
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
    logger.info("Removed endpoint: \(endpoint.name, privacy: .public)")
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
