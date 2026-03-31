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
  enum LayoutMode {
    case sheet
    case embedded
  }

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
  private let layoutMode: LayoutMode

  @MainActor
  init(endpointSettings: ServerEndpointSettingsClient? = nil, layoutMode: LayoutMode = .sheet) {
    let resolvedEndpointSettings = endpointSettings ?? .live()
    self.endpointSettings = resolvedEndpointSettings
    self.layoutMode = layoutMode
    _endpoints = State(initialValue: resolvedEndpointSettings.endpoints())
  }

  private var orderedEndpoints: [ServerEndpoint] {
    ServerSettingsSheetPlanner.orderedEndpoints(endpoints)
  }

  private var enabledEndpoints: [ServerEndpoint] {
    endpoints.filter(\.isEnabled)
  }

  private var connectedEndpointCount: Int {
    enabledEndpoints.filter { endpoint in
      runtimeRegistry.displayConnectionStatus(for: endpoint.id) == .connected
    }.count
  }

  private var failedEndpointCount: Int {
    enabledEndpoints.filter { endpoint in
      if case .failed = runtimeRegistry.displayConnectionStatus(for: endpoint.id) {
        return true
      }
      return false
    }.count
  }

  private var healthSummaryText: String {
    guard !enabledEndpoints.isEmpty else { return "No enabled endpoints" }
    if failedEndpointCount > 0 {
      return failedEndpointCount == 1 ? "1 endpoint needs attention" : "\(failedEndpointCount) endpoints need attention"
    }
    if connectedEndpointCount == enabledEndpoints.count {
      return connectedEndpointCount == 1 ? "1 endpoint live" : "\(connectedEndpointCount) endpoints live"
    }
    return "Sync in progress"
  }

  private var healthSummaryColor: Color {
    if enabledEndpoints.isEmpty {
      return Color.textTertiary
    }
    if failedEndpointCount > 0 {
      return Color.statusPermission
    }
    if connectedEndpointCount == enabledEndpoints.count {
      return Color.feedbackPositive
    }
    return Color.statusQuestion
  }

  // MARK: - Body

  var body: some View {
    Group {
      switch layoutMode {
        case .sheet:
          NavigationStack {
            content
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
        case .embedded:
          content
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
    .modifier(SheetPresentationModifier(isPresentedAsSheet: layoutMode == .sheet))
  }

  private var content: some View {
    Group {
      if layoutMode == .sheet {
        ScrollView {
          contentStack
            .padding(Spacing.section)
        }
      } else {
        contentStack
      }
    }
    .background(Color.backgroundPrimary)
  }

  private var contentStack: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      if layoutMode == .embedded {
        embeddedHeader
      }
      ForEach(orderedEndpoints) { endpoint in
        endpointCard(endpoint)
      }

      addEndpointButton
    }
  }

  private var embeddedHeader: some View {
    HStack(spacing: Spacing.md) {
      Circle()
        .fill(healthSummaryColor)
        .frame(width: 8, height: 8)
        .shadow(color: healthSummaryColor.opacity(0.45), radius: 4)

      VStack(alignment: .leading, spacing: Spacing.xxs) {
        Text("Endpoint Connection Health")
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.textSecondary)
        Text(healthSummaryText)
          .font(.system(size: TypeScale.meta, weight: .semibold, design: .monospaced))
          .foregroundStyle(healthSummaryColor)
      }

      Spacer()
    }
    .padding(Spacing.md)
    .background(
      Color.backgroundSecondary,
      in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .stroke(Color.panelBorder, lineWidth: 1)
    )
  }

  // MARK: - Endpoint Card (flat, no expand/collapse)

  private func endpointCard(_ endpoint: ServerEndpoint) -> some View {
    let endpointStatus = status(for: endpoint)
    let isPrimary = runtimeRegistry.primaryEndpointId == endpoint.id
    let isServerPrimary = runtimeRegistry.serverPrimaryByEndpointId[endpoint.id] == true
    let isConnected = endpointStatus == .connected
    let failurePresentation = failurePresentation(for: endpointStatus)
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
        endpointHeader(
          endpoint: endpoint,
          status: endpointStatus,
          statusColor: endpointStatusColor,
          isConnected: isConnected
        )

        if isPrimary {
          primaryBadge
        }

        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text(endpoint.wsURL.absoluteString)
            .font(.system(size: TypeScale.caption, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)
            .lineLimit(1)
            .truncationMode(.middle)
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
              .fixedSize(horizontal: false, vertical: true)
          }
        }

        // Row 3: Failure guidance banner (conditional)
        if let failurePresentation {
          HStack(spacing: Spacing.sm) {
            Image(systemName: failurePresentation.icon)
              .foregroundStyle(failurePresentation.color)
              .font(.system(size: IconScale.lg))
            VStack(alignment: .leading, spacing: Spacing.xxs) {
              Text(failurePresentation.title)
                .font(.system(size: TypeScale.body, weight: .semibold))
                .foregroundStyle(failurePresentation.color)
              Text(failurePresentation.detail)
                .font(.system(size: TypeScale.caption))
                .foregroundStyle(Color.textSecondary)
            }
          }
          .padding(Spacing.md)
          .background(
            failurePresentation.color.opacity(OpacityTier.light),
            in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
          )
          .overlay(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
              .stroke(failurePresentation.color.opacity(OpacityTier.subtle), lineWidth: 1)
          )
        }

        ScrollView(.horizontal, showsIndicators: false) {
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
          .padding(.vertical, Spacing.xxs)
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
          failurePresentation != nil
            ? endpointStatusColor.opacity(OpacityTier.medium)
            : Color.panelBorder,
          lineWidth: 1
        )
    )
    .clipped()
  }

  private func endpointHeader(
    endpoint: ServerEndpoint,
    status: ConnectionStatus,
    statusColor: Color,
    isConnected: Bool
  ) -> some View {
    HStack(alignment: .top, spacing: Spacing.sm) {
      endpointStatusDot(color: statusColor, isConnected: isConnected)

      VStack(alignment: .leading, spacing: Spacing.xxs) {
        Text(endpoint.name)
          .font(.system(size: TypeScale.title, weight: .semibold))
          .foregroundStyle(endpoint.isEnabled ? Color.textPrimary : Color.textTertiary)
          .lineLimit(2)
          .truncationMode(.tail)

        statusBadge(status: status, color: statusColor)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      HStack(spacing: Spacing.sm_) {
        if let action = connectionAction(for: status), endpoint.isEnabled {
          connectionActionButton(action: action, endpointID: endpoint.id, status: status)
        }

        endpointEnabledToggle(endpointID: endpoint.id, isEnabled: endpoint.isEnabled)
      }
    }
  }

  private func endpointStatusDot(color: Color, isConnected: Bool) -> some View {
    Circle()
      .fill(color)
      .frame(width: 7, height: 7)
      .shadow(color: isConnected ? color.opacity(0.4) : .clear, radius: 4)
  }

  private func statusBadge(status: ConnectionStatus, color: Color) -> some View {
    Text(statusLabel(for: status))
      .font(.system(size: TypeScale.caption, weight: .medium))
      .foregroundStyle(color)
  }

  private var primaryBadge: some View {
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

  private func connectionActionButton(
    action: (label: String, handler: (UUID) -> Void),
    endpointID: UUID,
    status: ConnectionStatus
  ) -> some View {
    Button {
      action.handler(endpointID)
    } label: {
      Image(systemName: connectionIcon(for: status))
      .font(.system(size: IconScale.lg, weight: .semibold))
      .foregroundStyle(Color.accent)
      .frame(width: 32, height: 32)
      .background(Color.accent.opacity(OpacityTier.subtle), in: Circle())
    }
    .buttonStyle(.plain)
  }

  private func endpointEnabledToggle(endpointID: UUID, isEnabled: Bool) -> some View {
    Toggle(
      isOn: Binding(
        get: { isEnabled },
        set: { nextEnabled in
          updateEndpointEnabled(endpointID, isEnabled: nextEnabled)
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

  private struct FailurePresentation {
    let title: String
    let detail: String
    let icon: String
    let color: Color
  }

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

  private func failurePresentation(for status: ConnectionStatus) -> FailurePresentation? {
    guard case let .failed(message) = status else { return nil }
    let lowered = message.lowercased()

    if lowered.contains("401") || lowered.contains("403") || lowered.contains("unauthorized")
      || lowered.contains("auth")
    {
      return FailurePresentation(
        title: "Authentication failed",
        detail: "Update the auth token for this server, then retry.",
        icon: "key.horizontal.fill",
        color: Color.statusPermission
      )
    }

    if lowered.contains("dns") || lowered.contains("hostname") || lowered.contains("resolve") {
      return FailurePresentation(
        title: "Hostname could not be resolved",
        detail: "OrbitDock is backing off retries to reduce noise. Verify DNS or endpoint host availability.",
        icon: "network.slash",
        color: Color.feedbackWarning
      )
    }

    if lowered.contains("websocket upgrade failed") || lowered.contains("reverse-proxy") {
      return FailurePresentation(
        title: "Realtime upgrade failed",
        detail: "HTTP is reachable, but `/ws` upgrade is blocked. Check proxy WebSocket upgrade settings.",
        icon: "bolt.horizontal.circle",
        color: Color.statusQuestion
      )
    }

    return FailurePresentation(
      title: "Connection failed",
      detail: message,
      icon: "exclamationmark.triangle.fill",
      color: Color.statusPermission
    )
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

private struct SheetPresentationModifier: ViewModifier {
  let isPresentedAsSheet: Bool

  @ViewBuilder
  func body(content: Content) -> some View {
    if isPresentedAsSheet {
      content
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    } else {
      content
    }
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
