//
//  ServerCommPanel.swift
//  OrbitDock
//
//  Comm-link console for server endpoint management.
//  Replaces the old settings sheet with a channel-based layout
//  where each endpoint is a live communication channel.
//

import os.log
import SwiftUI

private let commPanelLogger = Logger(subsystem: "com.orbitdock", category: "comm-panel")

struct ServerCommPanel: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry

  @State private var endpoints: [ServerEndpoint]
  @State private var editingEndpointId: UUID?
  @State private var isAddingEndpoint = false
  @State private var draft = ServerEndpointEditorDraft(
    name: "", hostInput: "", isEnabled: true, isDefault: false, authToken: ""
  )
  @State private var editorError: String?
  @State private var endpointPendingDelete: ServerEndpoint?
  private let endpointSettings: ServerEndpointSettingsClient

  @MainActor
  init(endpointSettings: ServerEndpointSettingsClient? = nil) {
    let resolved = endpointSettings ?? .live()
    self.endpointSettings = resolved
    _endpoints = State(initialValue: resolved.endpoints())
  }

  private var orderedEndpoints: [ServerEndpoint] {
    ServerSettingsSheetPlanner.orderedEndpoints(endpoints)
  }

  // MARK: - Aggregate status

  private var enabledEndpoints: [ServerEndpoint] {
    endpoints.filter(\.isEnabled)
  }

  private var connectedCount: Int {
    enabledEndpoints.filter { runtimeRegistry.displayConnectionStatus(for: $0.id) == .connected }.count
  }

  private var failedCount: Int {
    enabledEndpoints.filter {
      if case .failed = runtimeRegistry.displayConnectionStatus(for: $0.id) { return true }
      return false
    }.count
  }

  private var aggregateColor: Color {
    if enabledEndpoints.isEmpty { return Color.textTertiary }
    if failedCount > 0 { return Color.statusPermission }
    if connectedCount == enabledEndpoints.count { return Color.feedbackPositive }
    if connectedCount > 0 { return Color.statusQuestion }
    return Color.textTertiary
  }

  private var summaryText: String {
    let total = enabledEndpoints.count
    if total == 0 { return "No endpoints enabled" }
    if connectedCount == total {
      return total == 1 ? "Connected" : "\(connectedCount) connected"
    }
    if failedCount > 0 {
      return failedCount == 1 ? "1 endpoint failed" : "\(failedCount) failed"
    }
    return "Connecting\u{2026}"
  }

  // MARK: - Body

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      commHeader

      accentRule

      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(orderedEndpoints) { endpoint in
            if editingEndpointId == endpoint.id {
              channelEditor(endpointId: endpoint.id)
            } else {
              channelRow(endpoint)
            }
            accentRule
          }

          if isAddingEndpoint {
            channelEditor(endpointId: nil)
            accentRule
          }

          addButton
        }
      }
    }
    .background(Color.backgroundPrimary)
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
    .onAppear { refreshFromSettings() }
    .alert(
      "Remove Endpoint",
      isPresented: Binding(
        get: { endpointPendingDelete != nil },
        set: { if !$0 { endpointPendingDelete = nil } }
      ),
      presenting: endpointPendingDelete
    ) { endpoint in
      Button("Cancel", role: .cancel) { endpointPendingDelete = nil }
      Button("Remove", role: .destructive) { removeEndpoint(endpoint) }
    } message: { endpoint in
      Text("Remove \(endpoint.name)? Active connections will be stopped.")
    }
  }

  // MARK: - Header

  private var commHeader: some View {
    HStack(spacing: Spacing.md) {
      // Mini beacon — concentric rings
      ZStack {
        Circle()
          .stroke(Color.accent.opacity(OpacityTier.subtle), lineWidth: 1)
          .frame(width: 36, height: 36)

        Circle()
          .stroke(Color.accent.opacity(OpacityTier.tint), lineWidth: 1)
          .frame(width: 26, height: 26)

        Circle()
          .fill(aggregateColor.opacity(OpacityTier.medium))
          .frame(width: 14, height: 14)

        Circle()
          .fill(aggregateColor)
          .frame(width: 7, height: 7)
          .shadow(color: aggregateColor.opacity(0.5), radius: 4)
      }

      VStack(alignment: .leading, spacing: Spacing.xxs) {
        Text("Mission Control")
          .font(.system(size: TypeScale.title, weight: .bold))
          .foregroundStyle(Color.textPrimary)

        Text(summaryText)
          .font(.system(size: TypeScale.caption, design: .monospaced))
          .foregroundStyle(aggregateColor)
      }

      Spacer()

      Button("Done") { dismiss() }
        .font(.system(size: TypeScale.body, weight: .medium))
        .foregroundStyle(Color.accent)
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.md)
  }

  // MARK: - Channel Row (display mode)

  private func channelRow(_ endpoint: ServerEndpoint) -> some View {
    let endpointStatus = status(for: endpoint)
    let statusCol = statusColor(for: endpointStatus)
    let isConnected = endpointStatus == .connected
    let isPrimary = runtimeRegistry.primaryEndpointId == endpoint.id
    let authFail = isAuthFailure(endpointStatus)

    return HStack(alignment: .top, spacing: 0) {
      // Left edge bar
      Rectangle()
        .fill(statusCol)
        .frame(width: EdgeBar.width)
        .frame(maxHeight: .infinity)
        .shadow(color: isConnected ? statusCol.opacity(0.3) : .clear, radius: 3)

      VStack(alignment: .leading, spacing: Spacing.sm_) {
        // Name + status + toggle
        HStack(spacing: Spacing.sm) {
          Circle()
            .fill(statusCol)
            .frame(width: 6, height: 6)
            .shadow(color: isConnected ? statusCol.opacity(0.5) : .clear, radius: 3)

          Text(endpoint.name)
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(endpoint.isEnabled ? Color.textPrimary : Color.textTertiary)

          if isPrimary {
            Text("PRIMARY")
              .font(.system(size: TypeScale.mini, weight: .bold, design: .monospaced))
              .foregroundStyle(Color.accent)
              .padding(.horizontal, Spacing.xs)
              .padding(.vertical, 1)
              .background(Color.accent.opacity(OpacityTier.light), in: Capsule())
          }

          Spacer(minLength: Spacing.sm)

          Text(statusLabel(for: endpointStatus))
            .font(.system(size: TypeScale.caption, weight: .semibold, design: .monospaced))
            .foregroundStyle(statusCol)

          Toggle(
            isOn: Binding(
              get: { endpoint.isEnabled },
              set: { updateEndpointEnabled(endpoint.id, isEnabled: $0) }
            )
          ) { EmptyView() }
            .toggleStyle(.switch)
            .tint(Color.accent)
            .labelsHidden()
            .fixedSize()
            .scaleEffect(0.8)
        }

        // URL
        Text(endpoint.wsURL.absoluteString)
          .font(.system(size: TypeScale.caption, design: .monospaced))
          .foregroundStyle(Color.textQuaternary)
          .textSelection(.enabled)

        // Token display
        HStack(spacing: Spacing.sm_) {
          Image(systemName: "key.fill")
            .font(.system(size: IconScale.sm))
            .foregroundStyle(Color.textQuaternary)

          Text(tokenDisplayText(endpoint.authToken))
            .font(.system(size: TypeScale.caption, design: .monospaced))
            .foregroundStyle(
              endpoint.authToken != nil ? Color.textTertiary : Color.statusPermission.opacity(0.8)
            )
        }

        // Auth failure
        if authFail {
          HStack(spacing: Spacing.sm_) {
            Image(systemName: "exclamationmark.triangle.fill")
              .font(.system(size: IconScale.sm))
              .foregroundStyle(Color.statusPermission)
            Text("Authentication failed \u{2014} update token")
              .font(.system(size: TypeScale.caption, weight: .medium))
              .foregroundStyle(Color.statusPermission)
          }
          .padding(.vertical, Spacing.xs)
          .padding(.horizontal, Spacing.sm)
          .background(
            Color.statusPermission.opacity(OpacityTier.tint),
            in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
          )
        }

        // Actions
        HStack(spacing: Spacing.sm_) {
          actionPill("Edit", icon: "pencil", color: Color.textTertiary) {
            beginEditing(endpoint)
          }

          if let action = connectionAction(for: endpointStatus), endpoint.isEnabled {
            actionPill(action.label, icon: connectionIcon(for: endpointStatus), color: Color.accent) {
              action.handler(endpoint.id)
            }
          }

          if !isPrimary, endpoint.isEnabled {
            actionPill("Primary", icon: "crown", color: Color.accent) {
              setDefaultEndpoint(endpoint.id)
            }
          }

          if let roleAction = serverRoleAction(for: endpoint, status: endpointStatus) {
            actionPill(roleAction.label, icon: "server.rack", color: Color.textTertiary) {
              roleAction.handler(endpoint.id)
            }
          }

          actionPill("Remove", icon: "trash", color: Color.statusPermission.opacity(0.7)) {
            endpointPendingDelete = endpoint
          }
        }
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.md)
    }
  }

  // MARK: - Channel Editor (inline edit/add mode)

  private func channelEditor(endpointId: UUID?) -> some View {
    let isNew = endpointId == nil

    return HStack(alignment: .top, spacing: 0) {
      // Left edge bar — accent while editing
      Rectangle()
        .fill(Color.accent)
        .frame(width: EdgeBar.width)
        .frame(maxHeight: .infinity)

      VStack(alignment: .leading, spacing: 0) {
        // Header
        HStack {
          Image(systemName: "pencil.circle.fill")
            .font(.system(size: IconScale.xl))
            .foregroundStyle(Color.accent)
          Text(isNew ? "New Endpoint" : "Editing")
            .font(.system(size: TypeScale.caption, weight: .bold, design: .monospaced))
            .foregroundStyle(Color.accent)
          Spacer()
        }
        .padding(.horizontal, Spacing.md)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.sm)

        // Fields
        terminalField(icon: "tag", placeholder: "Server name", text: $draft.name)
        fieldDivider

        terminalField(
          icon: "globe",
          placeholder: "10.0.0.5:4000",
          text: $draft.hostInput,
          monospaced: true
        )
        fieldDivider

        terminalSecureField(
          icon: "key.fill",
          placeholder: "Paste auth token",
          text: $draft.authToken
        )
        fieldDivider

        toggleRow(icon: "power", label: "Enabled", isOn: $draft.isEnabled)
        fieldDivider

        toggleRow(icon: "crown", label: "Control Plane", isOn: $draft.isDefault)
          .disabled(!draft.isEnabled)

        // Error
        if let editorError {
          HStack(spacing: Spacing.sm_) {
            Image(systemName: "exclamationmark.triangle.fill")
              .font(.system(size: IconScale.sm))
              .foregroundStyle(Color.statusPermission)
            Text(editorError)
              .font(.system(size: TypeScale.caption, weight: .medium))
              .foregroundStyle(Color.statusPermission)
          }
          .padding(.horizontal, Spacing.md)
          .padding(.top, Spacing.sm)
        }

        // Save / Cancel
        HStack(spacing: Spacing.sm) {
          Spacer()

          Button { cancelEditing() } label: {
            Text("Cancel")
              .font(.system(size: TypeScale.caption, weight: .medium))
              .foregroundStyle(Color.textTertiary)
              .padding(.horizontal, Spacing.md)
              .padding(.vertical, Spacing.sm_)
          }
          .buttonStyle(.plain)

          Button { saveEditing() } label: {
            Text("Save")
              .font(.system(size: TypeScale.caption, weight: .bold))
              .foregroundStyle(Color.backgroundPrimary)
              .padding(.horizontal, Spacing.lg)
              .padding(.vertical, Spacing.sm_)
              .background(Color.accent, in: Capsule())
          }
          .buttonStyle(.plain)
          .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.md)
      }
    }
    .background(Color.accent.opacity(OpacityTier.tint))
  }

  // MARK: - Field Components

  private func terminalField(
    icon: String,
    placeholder: String,
    text: Binding<String>,
    monospaced: Bool = false
  ) -> some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: icon)
        .font(.system(size: IconScale.md))
        .foregroundStyle(Color.textQuaternary)
        .frame(width: 16, alignment: .center)

      TextField(placeholder, text: text)
        .textFieldStyle(.plain)
        .font(.system(size: TypeScale.body, design: monospaced ? .monospaced : .default))
        .foregroundStyle(Color.textPrimary)
      #if os(iOS)
        .textInputAutocapitalization(monospaced ? .never : .words)
      #endif
        .autocorrectionDisabled()
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
  }

  private func terminalSecureField(
    icon: String,
    placeholder: String,
    text: Binding<String>
  ) -> some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: icon)
        .font(.system(size: IconScale.md))
        .foregroundStyle(Color.textQuaternary)
        .frame(width: 16, alignment: .center)

      SecureField(placeholder, text: text)
        .textFieldStyle(.plain)
        .font(.system(size: TypeScale.body, design: .monospaced))
        .foregroundStyle(Color.textPrimary)
      #if os(iOS)
        .textInputAutocapitalization(.never)
      #endif
        .autocorrectionDisabled()
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
  }

  private func toggleRow(icon: String, label: String, isOn: Binding<Bool>) -> some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: icon)
        .font(.system(size: IconScale.md))
        .foregroundStyle(Color.textQuaternary)
        .frame(width: 16, alignment: .center)

      Text(label)
        .font(.system(size: TypeScale.body))
        .foregroundStyle(Color.textSecondary)

      Spacer()

      Toggle(isOn: isOn) { EmptyView() }
        .toggleStyle(.switch)
        .tint(Color.accent)
        .labelsHidden()
        .fixedSize()
        .scaleEffect(0.8)
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
  }

  private var fieldDivider: some View {
    Rectangle()
      .fill(Color.accent.opacity(OpacityTier.tint))
      .frame(height: 1)
      .padding(.leading, Spacing.md + 16 + Spacing.sm)
  }

  // MARK: - Add Endpoint

  private var addButton: some View {
    Button { beginAdding() } label: {
      HStack(spacing: Spacing.sm_) {
        Image(systemName: "plus")
          .font(.system(size: IconScale.sm, weight: .bold))
        Text("Add Endpoint")
          .font(.system(size: TypeScale.caption, weight: .semibold))
      }
      .foregroundStyle(Color.accent)
      .frame(maxWidth: .infinity)
      .padding(.vertical, Spacing.md)
    }
    .buttonStyle(.plain)
    .disabled(isAddingEndpoint)
  }

  // MARK: - Accent Rule

  private var accentRule: some View {
    Rectangle()
      .fill(Color.accent.opacity(OpacityTier.subtle))
      .frame(height: 1)
  }

  // MARK: - Action Pill

  private func actionPill(
    _ label: String,
    icon: String,
    color: Color,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: Spacing.gap) {
        Image(systemName: icon)
          .font(.system(size: 8, weight: .bold))
        Text(label)
          .font(.system(size: TypeScale.micro, weight: .bold))
      }
      .foregroundStyle(color)
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xs)
      .background(color.opacity(OpacityTier.subtle), in: Capsule())
    }
    .buttonStyle(.plain)
  }

  // MARK: - Token Display

  private func tokenDisplayText(_ token: String?) -> String {
    guard let token, !token.isEmpty else { return "no token" }
    if token.count <= 8 { return String(repeating: "\u{2022}", count: token.count) }
    let prefix = String(token.prefix(4))
    let suffix = String(token.suffix(4))
    return "\(prefix)\u{2022}\u{2022}\u{2022}\u{2022}\(suffix)"
  }

  // MARK: - Helpers

  private func status(for endpoint: ServerEndpoint) -> ConnectionStatus {
    endpoint.isEnabled
      ? runtimeRegistry.displayConnectionStatus(for: endpoint.id)
      : .disconnected
  }

  private func isAuthFailure(_ status: ConnectionStatus) -> Bool {
    guard case let .failed(message) = status else { return false }
    let lowered = message.lowercased()
    return lowered.contains("401") || lowered.contains("unauthorized") || lowered.contains("auth")
  }

  private func statusLabel(for status: ConnectionStatus) -> String {
    switch status {
      case .connected: "LIVE"
      case .connecting: "SYNC"
      case .disconnected: "OFF"
      case .failed: "FAIL"
    }
  }

  private func statusColor(for status: ConnectionStatus) -> Color {
    switch status {
      case .connected: Color.feedbackPositive
      case .connecting: Color.statusQuestion
      case .disconnected: Color.textTertiary
      case .failed: Color.statusPermission
    }
  }

  private func connectionIcon(for status: ConnectionStatus) -> String {
    switch status {
      case .connected: "bolt.slash"
      case .connecting: "xmark"
      case .disconnected: "bolt"
      case .failed: "arrow.clockwise"
    }
  }

  private func connectionAction(for status: ConnectionStatus) -> (label: String, handler: (UUID) -> Void)? {
    switch status {
      case .connected:
        ("Disconnect", { runtimeRegistry.stop(endpointId: $0) })
      case .connecting:
        ("Cancel", { runtimeRegistry.stop(endpointId: $0) })
      case .disconnected:
        ("Connect", { runtimeRegistry.reconnect(endpointId: $0) })
      case .failed:
        ("Retry", { runtimeRegistry.reconnect(endpointId: $0) })
    }
  }

  private func serverRoleAction(
    for endpoint: ServerEndpoint,
    status: ConnectionStatus
  ) -> (label: String, handler: (UUID) -> Void)? {
    guard endpoint.isEnabled, case .connected = status else { return nil }
    if runtimeRegistry.serverPrimaryByEndpointId[endpoint.id] == true {
      return ("Secondary", { runtimeRegistry.setServerRole(endpointId: $0, isPrimary: false) })
    }
    return ("Primary Role", { runtimeRegistry.setServerRole(endpointId: $0, isPrimary: true) })
  }

  // MARK: - State Mutations

  private func beginEditing(_ endpoint: ServerEndpoint) {
    editingEndpointId = endpoint.id
    isAddingEndpoint = false
    draft = ServerSettingsSheetPlanner.editDraft(
      endpoint: endpoint,
      hostInput: endpointSettings.hostInput(endpoint.wsURL) ?? endpoint.wsURL.host ?? ""
    )
    editorError = nil
  }

  private func beginAdding() {
    editingEndpointId = nil
    isAddingEndpoint = true
    draft = ServerSettingsSheetPlanner.addDraft(existingEndpoints: endpoints)
    editorError = nil
  }

  private func cancelEditing() {
    editingEndpointId = nil
    isAddingEndpoint = false
    draft.authToken = ""
    editorError = nil
  }

  private func saveEditing() {
    switch ServerSettingsSheetPlanner.save(
      currentEndpoints: endpoints,
      editingEndpointID: editingEndpointId,
      draft: draft,
      defaultPort: endpointSettings.defaultPort,
      buildURL: endpointSettings.buildURL
    ) {
      case let .success(updated):
        persistEndpoints(updated)
        cancelEditing()
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
  ServerCommPanel()
    .environment(runtimeRegistry)
    .preferredColorScheme(.dark)
}
