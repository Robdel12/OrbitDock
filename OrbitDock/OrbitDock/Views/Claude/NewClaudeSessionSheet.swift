//
//  NewClaudeSessionSheet.swift
//  OrbitDock
//
//  Sheet for creating new direct Claude sessions.
//  Matches the Codex sheet pattern — directory → config card → launch.
//

import SwiftUI

struct NewClaudeSessionSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(ServerAppState.self) private var serverState
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry

  @State private var selectedPath: String = ""
  @State private var selectedEndpointId: UUID = ServerEndpointSettings.defaultEndpoint.id
  @State private var selectedModelId: String = ""
  @State private var customModelInput: String = ""
  @State private var useCustomModel = false
  @State private var isCreating = false
  @State private var selectedPermissionMode: ClaudePermissionMode = .default
  @State private var allowedToolsText: String = ""
  @State private var disallowedToolsText: String = ""
  @State private var showToolConfig = false
  @State private var selectedEffort: String? = nil

  private var canCreateSession: Bool {
    !selectedPath.isEmpty && !isCreating && isEndpointConnected
  }

  private var availableModels: [ServerClaudeModelOption] {
    endpointAppState.claudeModels
  }

  private var resolvedModel: String? {
    if useCustomModel {
      let trimmed = customModelInput.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    return selectedModelId.isEmpty ? nil : selectedModelId
  }

  private var selectableEndpoints: [ServerEndpoint] {
    let enabled = ServerEndpointSettings.endpoints.filter(\.isEnabled)
    return enabled.isEmpty ? ServerEndpointSettings.endpoints : enabled
  }

  private var endpointAppState: ServerAppState {
    runtimeRegistry.appState(for: selectedEndpointId, fallback: serverState)
  }

  private var endpointStatus: ConnectionStatus {
    runtimeRegistry.connectionStatusByEndpointId[selectedEndpointId]
      ?? runtimeRegistry.connection(for: selectedEndpointId)?.status
      ?? .disconnected
  }

  private var isEndpointConnected: Bool {
    if case .connected = endpointStatus {
      return true
    }
    return false
  }

  private var shouldShowEndpointSection: Bool {
    selectableEndpoints.count > 1 || !isEndpointConnected
  }

  var body: some View {
    VStack(spacing: 0) {
      header

      Divider()
        .overlay(Color.surfaceBorder)

      // Form content
      VStack(alignment: .leading, spacing: Spacing.xl) {
        if shouldShowEndpointSection {
          endpointSection
        }
        directorySection
        configurationCard
        toolRestrictionsCard
      }
      .padding(Spacing.xl)

      Spacer(minLength: 0)

      Divider()
        .overlay(Color.surfaceBorder)

      footer
    }
    .frame(minWidth: 420, idealWidth: 500, maxWidth: 580)
    .background(Color.backgroundSecondary)
    .onAppear {
      if let primaryEndpointId = runtimeRegistry.primaryEndpointId,
         selectableEndpoints.contains(where: { $0.id == primaryEndpointId })
      {
        selectedEndpointId = primaryEndpointId
      }
      normalizeEndpointSelection()
      endpointAppState.refreshClaudeModels()
      if availableModels.isEmpty {
        useCustomModel = true
      } else if selectedModelId.isEmpty, let firstModel = availableModels.first {
        selectedModelId = firstModel.value
      }
    }
    .onChange(of: selectedEndpointId) { _, _ in
      selectedPath = ""
      selectedModelId = ""
      customModelInput = ""
      useCustomModel = false
      normalizeEndpointSelection()
      endpointAppState.refreshClaudeModels()
      if availableModels.isEmpty {
        useCustomModel = true
      } else if selectedModelId.isEmpty, let firstModel = availableModels.first {
        selectedModelId = firstModel.value
      }
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: Spacing.md) {
      Image(systemName: "plus.circle.fill")
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(Color.providerClaude)

      Text("New Claude Session")
        .font(.system(size: TypeScale.title, weight: .semibold))
        .foregroundStyle(Color.textPrimary)

      Spacer()

      Button {
        dismiss()
      } label: {
        Image(systemName: "xmark.circle.fill")
          .font(.system(size: 16))
          .foregroundStyle(Color.textQuaternary)
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, Spacing.xl)
    .padding(.vertical, Spacing.lg)
  }

  // MARK: - Directory

  private var endpointSection: some View {
    EndpointSelectorField(
      endpoints: selectableEndpoints,
      statusByEndpointId: runtimeRegistry.connectionStatusByEndpointId,
      serverPrimaryByEndpointId: runtimeRegistry.serverPrimaryByEndpointId,
      selectedEndpointId: $selectedEndpointId,
      onReconnect: { endpointId in
        runtimeRegistry.reconnect(endpointId: endpointId)
      }
    )
  }

  private var directorySection: some View {
    #if os(iOS)
      RemoteProjectPicker(selectedPath: $selectedPath, endpointId: selectedEndpointId)
    #else
      ProjectPicker(selectedPath: $selectedPath, endpointId: selectedEndpointId)
    #endif
  }

  // MARK: - Configuration Card (Model + Permission)

  private var configurationCard: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Model row
      HStack {
        HStack(spacing: Spacing.sm) {
          Image(systemName: "cpu")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.textTertiary)
          Text("Model")
            .font(.system(size: TypeScale.body, weight: .medium))
            .foregroundStyle(Color.textSecondary)
        }

        Spacer()

        if useCustomModel {
          TextField("e.g. claude-sonnet-4-5-20250929", text: $customModelInput)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: TypeScale.body, design: .monospaced))
            .frame(maxWidth: 220)
        } else {
          Picker("Model", selection: $selectedModelId) {
            ForEach(availableModels) { model in
              Text(model.displayName).tag(model.value)
            }
          }
          .pickerStyle(.menu)
          .labelsHidden()
          .fixedSize()
        }

        Button {
          useCustomModel.toggle()
          if !useCustomModel {
            customModelInput = ""
          }
        } label: {
          Text(useCustomModel ? "Picker" : "Custom")
            .font(.system(size: TypeScale.caption, weight: .medium))
            .foregroundStyle(Color.accent)
        }
        .buttonStyle(.plain)
      }
      .padding(.horizontal, Spacing.lg)
      .padding(.vertical, Spacing.md)

      Divider()
        .padding(.horizontal, Spacing.lg)

      // Permission mode row — selector + detail integrated
      VStack(alignment: .leading, spacing: Spacing.md) {
        HStack {
          HStack(spacing: Spacing.sm) {
            Image(systemName: selectedPermissionMode.icon)
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(selectedPermissionMode.color)
            Text("Permission")
              .font(.system(size: TypeScale.body, weight: .medium))
              .foregroundStyle(Color.textSecondary)
          }

          Spacer()

          CompactClaudePermissionSelector(selection: $selectedPermissionMode)
        }

        // Selected mode detail
        HStack(spacing: Spacing.sm) {
          RoundedRectangle(cornerRadius: 1.5)
            .fill(selectedPermissionMode.color)
            .frame(width: 2)

          VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(spacing: Spacing.sm) {
              Text(selectedPermissionMode.displayName)
                .font(.system(size: TypeScale.body, weight: .semibold))
                .foregroundStyle(selectedPermissionMode.color)

              if selectedPermissionMode.isDefault {
                Text("DEFAULT")
                  .font(.system(size: 7, weight: .bold, design: .rounded))
                  .foregroundStyle(selectedPermissionMode.color)
                  .padding(.horizontal, 4)
                  .padding(.vertical, 1.5)
                  .background(selectedPermissionMode.color.opacity(OpacityTier.light), in: Capsule())
              }
            }

            Text(selectedPermissionMode.description)
              .font(.system(size: TypeScale.caption))
              .foregroundStyle(Color.textTertiary)
          }
        }
        .padding(Spacing.sm)
        .background(
          selectedPermissionMode.color.opacity(OpacityTier.tint),
          in: RoundedRectangle(cornerRadius: Radius.md)
        )
        .animation(.easeOut(duration: 0.15), value: selectedPermissionMode)
      }
      .padding(.horizontal, Spacing.lg)
      .padding(.vertical, Spacing.md)
    }
    .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.lg))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg)
        .stroke(Color.surfaceBorder, lineWidth: 1)
    )
  }

  // MARK: - Tool Restrictions Card

  private var toolRestrictionsCard: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(.easeOut(duration: 0.15)) {
          showToolConfig.toggle()
        }
      } label: {
        HStack(spacing: Spacing.sm) {
          Image(systemName: "wrench.and.screwdriver")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.textTertiary)
          Text("Tool Restrictions")
            .font(.system(size: TypeScale.body, weight: .medium))
            .foregroundStyle(Color.textSecondary)

          Spacer()

          Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Color.textQuaternary)
            .rotationEffect(.degrees(showToolConfig ? 90 : 0))
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if showToolConfig {
        Divider()
          .padding(.horizontal, Spacing.lg)

        VStack(alignment: .leading, spacing: Spacing.md) {
          VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Allowed Tools")
              .font(.system(size: TypeScale.caption, weight: .medium))
              .foregroundStyle(Color.textTertiary)
            TextField("e.g. Read, Glob, Bash(git:*)", text: $allowedToolsText)
              .textFieldStyle(.roundedBorder)
              .font(.system(size: TypeScale.body, design: .monospaced))
          }

          VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Disallowed Tools")
              .font(.system(size: TypeScale.caption, weight: .medium))
              .foregroundStyle(Color.textTertiary)
            TextField("e.g. Write, Edit", text: $disallowedToolsText)
              .textFieldStyle(.roundedBorder)
              .font(.system(size: TypeScale.body, design: .monospaced))
          }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
      }
    }
    .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.lg))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg)
        .stroke(Color.surfaceBorder, lineWidth: 1)
    )
  }

  // MARK: - Footer

  private var footer: some View {
    HStack(spacing: Spacing.md) {
      Spacer()

      Button("Cancel") {
        dismiss()
      }
      .keyboardShortcut(.escape, modifiers: [])

      Button {
        createSession()
      } label: {
        if isCreating {
          ProgressView()
            .controlSize(.small)
            .frame(width: 70)
        } else {
          Label("Launch", systemImage: "paperplane.fill")
            .font(.system(size: TypeScale.body, weight: .semibold))
            .frame(width: 70)
        }
      }
      .buttonStyle(.borderedProminent)
      .tint(Color.providerClaude)
      .disabled(!canCreateSession)
      .keyboardShortcut(.return, modifiers: .command)
    }
    .padding(.horizontal, Spacing.xl)
    .padding(.vertical, Spacing.lg)
  }

  // MARK: - Actions

  private func parseToolList(_ text: String) -> [String] {
    text.split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }

  private func normalizeEndpointSelection() {
    guard !selectableEndpoints.isEmpty else { return }
    if selectableEndpoints.contains(where: { $0.id == selectedEndpointId }) {
      return
    }
    if let primaryEndpointId = runtimeRegistry.primaryEndpointId,
       selectableEndpoints.contains(where: { $0.id == primaryEndpointId })
    {
      selectedEndpointId = primaryEndpointId
      return
    }
    selectedEndpointId = selectableEndpoints.first(where: \.isDefault)?.id
      ?? selectableEndpoints.first?.id
      ?? selectedEndpointId
  }

  private func createSession() {
    guard !selectedPath.isEmpty else { return }
    endpointAppState.createClaudeSession(
      cwd: selectedPath,
      model: resolvedModel,
      permissionMode: selectedPermissionMode == .default ? nil : selectedPermissionMode.rawValue,
      allowedTools: parseToolList(allowedToolsText),
      disallowedTools: parseToolList(disallowedToolsText),
      effort: selectedEffort
    )
    dismiss()
  }
}

// MARK: - Compact Permission Selector

/// Horizontal pill selector for Claude permission modes.
/// Mirrors the CompactAutonomySelector pattern from Codex.
private struct CompactClaudePermissionSelector: View {
  @Binding var selection: ClaudePermissionMode
  @State private var hoveredMode: ClaudePermissionMode?

  private let modes = ClaudePermissionMode.allCases

  var body: some View {
    HStack(spacing: Spacing.xs) {
      ForEach(modes) { mode in
        let isActive = mode == selection
        let isHovered = hoveredMode == mode && !isActive

        Button {
          selection = mode
        } label: {
          Image(systemName: mode.icon)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(
              isActive
                ? Color.backgroundSecondary
                : isHovered
                ? mode.color
                : mode.color.opacity(0.5)
            )
            .frame(width: 28, height: 28)
            .background(
              Circle()
                .fill(
                  isActive
                    ? mode.color
                    : isHovered
                    ? mode.color.opacity(OpacityTier.light)
                    : Color.clear
                )
            )
            .overlay(
              Circle()
                .stroke(
                  isActive
                    ? Color.clear
                    : isHovered
                    ? mode.color.opacity(OpacityTier.strong)
                    : mode.color.opacity(OpacityTier.medium),
                  lineWidth: 1
                )
            )
            .shadow(color: isActive ? mode.color.opacity(0.3) : .clear, radius: 4)
        }
        .buttonStyle(.plain)
        #if !os(iOS)
          .onHover { hovering in
            hoveredMode = hovering ? mode : nil
          }
          .help(mode.displayName)
        #endif
          .contentShape(Circle())
      }
    }
    #if !os(iOS)
    .onHover { hovering in
      if hovering {
        NSCursor.pointingHand.push()
      } else {
        NSCursor.pop()
        hoveredMode = nil
      }
    }
    #endif
    .animation(.easeOut(duration: 0.12), value: hoveredMode)
    .animation(.easeOut(duration: 0.15), value: selection)
  }
}

#Preview {
  NewClaudeSessionSheet()
    .environment(ServerAppState())
    .environment(ServerRuntimeRegistry.shared)
}
