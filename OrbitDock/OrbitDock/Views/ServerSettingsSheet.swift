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

  private var enabledCount: Int {
    endpoints.filter(\.isEnabled).count
  }

  private var connectedCount: Int {
    endpoints.filter { endpoint in
      if case .connected = status(for: endpoint) {
        return true
      }
      return false
    }.count
  }

  private var failedCount: Int {
    endpoints.filter { endpoint in
      if case .failed = status(for: endpoint) {
        return true
      }
      return false
    }.count
  }

  private var usesCompactLayout: Bool {
    #if os(iOS)
      horizontalSizeClass == .compact
    #else
      false
    #endif
  }

  private var primaryEndpointName: String {
    if let primaryEndpointId = runtimeRegistry.primaryEndpointId,
       let endpoint = endpoints.first(where: { $0.id == primaryEndpointId })
    {
      return endpoint.name
    }
    return endpoints.first(where: { $0.isDefault && $0.isEnabled })?.name
      ?? endpoints.first(where: \.isEnabled)?.name
      ?? "None"
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          overviewCard

          VStack(alignment: .leading, spacing: usesCompactLayout ? 12 : 10) {
            HStack {
              Text("Endpoints")
                .font(.system(size: usesCompactLayout ? 15 : TypeScale.subhead, weight: .semibold))
                .foregroundStyle(Color.textPrimary)

              Spacer()

              Button {
                beginAddingEndpoint()
              } label: {
                HStack(spacing: 5) {
                  Image(systemName: "plus")
                  Text("Add Endpoint")
                }
                .font(.system(size: usesCompactLayout ? 13 : TypeScale.caption, weight: .semibold))
                .foregroundStyle(Color.accent)
                .padding(.horizontal, usesCompactLayout ? 12 : 8)
                .padding(.vertical, usesCompactLayout ? 8 : 6)
                .background(Color.accent.opacity(OpacityTier.light), in: Capsule())
              }
              .buttonStyle(.plain)
            }

            ForEach(orderedEndpoints) { endpoint in
              endpointCard(endpoint)
            }
          }
        }
        .padding(usesCompactLayout ? 16 : 20)
      }
      .background(Color.backgroundPrimary)
      .navigationTitle("Server Endpoints")
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

  private var overviewCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Status")
        .font(.system(size: usesCompactLayout ? 15 : TypeScale.subhead, weight: .semibold))
        .foregroundStyle(Color.textPrimary)

      if usesCompactLayout {
        VStack(spacing: 8) {
          HStack(spacing: 10) {
            statusMetric(
              icon: "network",
              value: "\(connectedCount)/\(enabledCount)",
              label: "Connected",
              color: connectedCount == enabledCount ? Color.statusWorking : Color.statusQuestion
            )

            statusMetric(
              icon: "exclamationmark.triangle.fill",
              value: "\(failedCount)",
              label: "Failed",
              color: failedCount == 0 ? Color.textTertiary : Color.statusPermission
            )
          }

          statusMetric(
            icon: "crown.fill",
            value: primaryEndpointName,
            label: "Control Plane",
            color: Color.accent,
            monospaced: false
          )
        }
      } else {
        HStack(spacing: 10) {
          statusMetric(
            icon: "network",
            value: "\(connectedCount)/\(enabledCount)",
            label: "Connected",
            color: connectedCount == enabledCount ? Color.statusWorking : Color.statusQuestion
          )

          statusMetric(
            icon: "exclamationmark.triangle.fill",
            value: "\(failedCount)",
            label: "Failed",
            color: failedCount == 0 ? Color.textTertiary : Color.statusPermission
          )

          statusMetric(
            icon: "crown.fill",
            value: primaryEndpointName,
            label: "Control Plane",
            color: Color.accent,
            monospaced: false
          )
        }
      }

      Text(
        "Control-plane selection is local to this device. Server-declared primary role and active client claims are shown as metadata."
      )
      .font(.system(size: TypeScale.caption))
      .foregroundStyle(Color.textTertiary)

      if runtimeRegistry.hasPrimaryEndpointConflict {
        Text("Multiple connected servers currently report Server Primary role.")
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.statusPermission)
      }
    }
    .padding(14)
    .background(Color.backgroundSecondary, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .stroke(Color.panelBorder, lineWidth: 1)
    )
  }

  private func statusMetric(
    icon: String,
    value: String,
    label: String,
    color: Color,
    monospaced: Bool = true
  ) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 4) {
        Image(systemName: icon)
          .font(.system(size: 10, weight: .semibold))
        Text(value)
          .font(.system(size: TypeScale.caption, weight: .bold, design: monospaced ? .monospaced : .default))
          .lineLimit(1)
      }
      .foregroundStyle(color)

      Text(label)
        .font(.system(size: TypeScale.micro, weight: .medium))
        .foregroundStyle(Color.textQuaternary)
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(
      Color.backgroundTertiary.opacity(0.7),
      in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
    )
  }

  private func endpointCard(_ endpoint: ServerEndpoint) -> some View {
    let endpointStatus = status(for: endpoint)

    return VStack(alignment: .leading, spacing: usesCompactLayout ? 12 : 10) {
      // MARK: Header — name, badges, status chip

      if usesCompactLayout {
        compactEndpointHeader(endpoint, status: endpointStatus)
      } else {
        regularEndpointHeader(endpoint, status: endpointStatus)
      }

      // MARK: Actions — toggle, connection, edit/remove

      if usesCompactLayout {
        compactEndpointActions(endpoint, status: endpointStatus)
      } else {
        regularEndpointActions(endpoint, status: endpointStatus)
      }
    }
    .padding(usesCompactLayout ? 16 : 12)
    .background(Color.backgroundSecondary, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .stroke(Color.panelBorder, lineWidth: 1)
    )
  }

  // MARK: - Compact Endpoint Header (iOS)

  private func compactEndpointHeader(_ endpoint: ServerEndpoint, status: ConnectionStatus) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .top) {
        Text(endpoint.name)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(Color.textPrimary)
          .lineLimit(1)

        Spacer(minLength: 8)

        connectionStatusChip(status: status)
      }

      let badges = endpointBadges(for: endpoint)
      if !badges.isEmpty {
        WrappingFlowLayout(spacing: 6) {
          ForEach(badges, id: \.label) { badge in
            EndpointBadge(endpointName: badge.label, isDefault: badge.isDefault)
          }
        }
      }

      Text(endpoint.wsURL.absoluteString)
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(Color.textQuaternary)
        .lineLimit(1)

      if let claimsText = claimingDevicesDescription(for: endpoint) {
        Text(claimsText)
          .font(.system(size: 11))
          .foregroundStyle(Color.textTertiary)
          .lineLimit(2)
      }
    }
  }

  // MARK: - Regular Endpoint Header (macOS / iPad)

  private func regularEndpointHeader(_ endpoint: ServerEndpoint, status: ConnectionStatus) -> some View {
    HStack(alignment: .top, spacing: 8) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Text(endpoint.name)
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(Color.textPrimary)
            .lineLimit(1)

          if runtimeRegistry.primaryEndpointId == endpoint.id {
            EndpointBadge(endpointName: "Control Plane", isDefault: true)
          }

          if runtimeRegistry.serverPrimaryByEndpointId[endpoint.id] == true {
            EndpointBadge(endpointName: "Server Primary")
          }

          let claimCount = runtimeRegistry.serverPrimaryClaimsByEndpointId[endpoint.id]?.count ?? 0
          if claimCount > 0 {
            EndpointBadge(endpointName: "Claimed ×\(claimCount)")
          }

          if endpoint.isLocalManaged {
            EndpointBadge(endpointName: "Local")
          }

          if !endpoint.isEnabled {
            EndpointBadge(endpointName: "Disabled")
          }
        }

        Text(endpoint.wsURL.absoluteString)
          .font(.system(size: TypeScale.caption, design: .monospaced))
          .foregroundStyle(Color.textQuaternary)
          .lineLimit(1)

        if let claimsText = claimingDevicesDescription(for: endpoint) {
          Text(claimsText)
            .font(.system(size: TypeScale.micro))
            .foregroundStyle(Color.textTertiary)
            .lineLimit(2)
        }
      }

      Spacer(minLength: 10)

      connectionStatusChip(status: status)
    }
  }

  // MARK: - Compact Endpoint Actions (iOS)

  private func compactEndpointActions(_ endpoint: ServerEndpoint, status: ConnectionStatus) -> some View {
    VStack(spacing: 10) {
      // Row 1: Toggle + connection action
      HStack {
        Toggle(
          isOn: Binding(
            get: { endpoint.isEnabled },
            set: { isEnabled in
              updateEndpointEnabled(endpoint.id, isEnabled: isEnabled)
            }
          )
        ) {
          Text("Enabled")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.textSecondary)
        }
        .toggleStyle(.switch)

        Spacer()

        if let action = connectionAction(for: status), endpoint.isEnabled {
          Button(action.label) {
            action.handler(endpoint.id)
          }
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(Color.accent)
          .buttonStyle(.borderless)
        }
      }

      // Row 2: Primary actions — full-width capsule buttons
      if endpoint.isEnabled {
        if runtimeRegistry.primaryEndpointId != endpoint.id {
          Button {
            setDefaultEndpoint(endpoint.id)
          } label: {
            Text("Use for This Device")
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(Color.accent)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 8)
              .background(Color.accent.opacity(OpacityTier.light), in: Capsule())
          }
          .buttonStyle(.plain)
        }

        if let roleAction = serverRoleAction(for: endpoint, status: status) {
          Button {
            roleAction.handler(endpoint.id)
          } label: {
            Text(roleAction.label)
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(Color.textSecondary)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 8)
              .background(Color.backgroundTertiary, in: Capsule())
          }
          .buttonStyle(.plain)
        }
      }

      // Row 3: Edit + Remove (trailing text buttons)
      HStack {
        Spacer()

        Button("Edit") {
          beginEditing(endpoint)
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Color.accent)
        .buttonStyle(.borderless)

        if !endpoint.isLocalManaged {
          Button("Remove") {
            endpointPendingDelete = endpoint
          }
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(Color.statusPermission)
          .buttonStyle(.borderless)
        }
      }
    }
  }

  // MARK: - Regular Endpoint Actions (macOS / iPad)

  private func regularEndpointActions(_ endpoint: ServerEndpoint, status: ConnectionStatus) -> some View {
    HStack(spacing: 8) {
      Toggle(
        isOn: Binding(
          get: { endpoint.isEnabled },
          set: { isEnabled in
            updateEndpointEnabled(endpoint.id, isEnabled: isEnabled)
          }
        )
      ) {
        Text("Enabled")
          .font(.system(size: TypeScale.caption, weight: .medium))
          .foregroundStyle(Color.textSecondary)
      }
      .toggleStyle(.switch)

      Spacer()

      if let action = connectionAction(for: status), endpoint.isEnabled {
        Button(action.label) {
          action.handler(endpoint.id)
        }
        .buttonStyle(.borderless)
        .font(.system(size: TypeScale.caption, weight: .semibold))
        .foregroundStyle(Color.accent)
      }

      if let roleAction = serverRoleAction(for: endpoint, status: status) {
        Button(roleAction.label) {
          roleAction.handler(endpoint.id)
        }
        .buttonStyle(.borderless)
        .font(.system(size: TypeScale.caption, weight: .semibold))
        .foregroundStyle(Color.accent)
      }

      if runtimeRegistry.primaryEndpointId != endpoint.id {
        Button("Use for This Device") {
          setDefaultEndpoint(endpoint.id)
        }
        .buttonStyle(.borderless)
        .font(.system(size: TypeScale.caption, weight: .semibold))
        .disabled(!endpoint.isEnabled)
      }

      Button("Edit") {
        beginEditing(endpoint)
      }
      .buttonStyle(.borderless)
      .font(.system(size: TypeScale.caption, weight: .semibold))

      if !endpoint.isLocalManaged {
        Button("Remove", role: .destructive) {
          endpointPendingDelete = endpoint
        }
        .buttonStyle(.borderless)
        .font(.system(size: TypeScale.caption, weight: .semibold))
      }
    }
  }

  // MARK: - Badge Data Helper

  private struct BadgeInfo: Hashable {
    let label: String
    let isDefault: Bool
  }

  private func endpointBadges(for endpoint: ServerEndpoint) -> [BadgeInfo] {
    var badges: [BadgeInfo] = []
    if runtimeRegistry.primaryEndpointId == endpoint.id {
      badges.append(BadgeInfo(label: "Control Plane", isDefault: true))
    }
    if runtimeRegistry.serverPrimaryByEndpointId[endpoint.id] == true {
      badges.append(BadgeInfo(label: "Server Primary", isDefault: false))
    }
    let claimCount = runtimeRegistry.serverPrimaryClaimsByEndpointId[endpoint.id]?.count ?? 0
    if claimCount > 0 {
      badges.append(BadgeInfo(label: "Claimed ×\(claimCount)", isDefault: false))
    }
    if endpoint.isLocalManaged {
      badges.append(BadgeInfo(label: "Local", isDefault: false))
    }
    if !endpoint.isEnabled {
      badges.append(BadgeInfo(label: "Disabled", isDefault: false))
    }
    return badges
  }

  private func connectionStatusChip(status: ConnectionStatus) -> some View {
    HStack(spacing: 5) {
      Circle()
        .fill(statusColor(for: status))
        .frame(width: 7, height: 7)
      Text(statusLabel(for: status))
        .font(.system(size: TypeScale.micro, weight: .semibold))
        .foregroundStyle(Color.textSecondary)
    }
    .padding(.horizontal, 7)
    .padding(.vertical, 4)
    .background(Color.backgroundTertiary, in: Capsule())
  }

  private var endpointEditorSheet: some View {
    NavigationStack {
      Form {
        Section("Details") {
          TextField("Name", text: $draftName)
          #if os(iOS)
            .textInputAutocapitalization(.words)
          #endif

          TextField("Host", text: $draftHostInput)
          #if os(iOS)
            .textInputAutocapitalization(.never)
          #endif
            .autocorrectionDisabled()
            .disabled(draftIsLocalManaged)

          if draftIsLocalManaged {
            Text("Local endpoint host is managed automatically.")
              .font(.system(size: TypeScale.caption))
              .foregroundStyle(Color.textTertiary)
          } else {
            Text("Examples: 10.0.0.5 or 10.0.0.5:4100")
              .font(.system(size: TypeScale.caption))
              .foregroundStyle(Color.textTertiary)
          }
        }

        Section("Behavior") {
          Toggle("Enabled", isOn: $draftIsEnabled)
          Toggle("Control-plane endpoint on this device", isOn: $draftIsDefault)
            .disabled(!draftIsEnabled)
        }

        if let editorError {
          Section {
            Text(editorError)
              .foregroundStyle(Color.statusPermission)
              .font(.system(size: TypeScale.caption, weight: .medium))
          }
        }
      }
      .navigationTitle(editingEndpointId == nil ? "Add Endpoint" : "Edit Endpoint")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
              closeEditor()
            }
          }
          ToolbarItem(placement: .confirmationAction) {
            Button("Save") {
              saveEditor()
            }
            .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }
    }
  }

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
      return ("Mark Server Secondary", { endpointId in
        runtimeRegistry.setServerRole(endpointId: endpointId, isPrimary: false)
      })
    }

    return ("Mark Server Primary", { endpointId in
      runtimeRegistry.setServerRole(endpointId: endpointId, isPrimary: true)
    })
  }

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
