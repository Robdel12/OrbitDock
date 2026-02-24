//
//  NewCodexSessionSheet.swift
//  OrbitDock
//
//  Sheet for creating new direct Codex sessions.
//  Clean, focused form: directory → model → autonomy → launch.
//

import SwiftUI

struct NewCodexSessionSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(ServerAppState.self) private var serverState
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry

  @State private var selectedPath: String = ""
  @State private var selectedModel: String = ""
  @State private var selectedAutonomy: AutonomyLevel = .autonomous
  @State private var selectedEndpointId: UUID = ServerEndpointSettings.defaultEndpoint.id
  @State private var isCreating = false
  @State private var errorMessage: String?

  private var modelOptions: [ServerCodexModelOption] {
    endpointAppState.codexModels
  }

  private var requiresLogin: Bool {
    endpointAppState.codexRequiresOpenAIAuth && endpointAppState.codexAccount == nil
  }

  private var canCreateSession: Bool {
    !selectedPath.isEmpty && !selectedModel.isEmpty && !isCreating && !requiresLogin && isEndpointConnected
  }

  private var defaultModelSelection: String {
    if let model = modelOptions.first(where: { $0.isDefault && !$0.model.isEmpty })?.model {
      return model
    }
    return modelOptions.first(where: { !$0.model.isEmpty })?.model ?? ""
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
      // Header — title + auth status in one line
      header

      Divider()
        .overlay(Color.surfaceBorder)

      // Form content
      VStack(alignment: .leading, spacing: Spacing.xl) {
        // Auth gate — only shows when not connected
        if endpointAppState.codexAccount == nil {
          authGateSection
        }

        if shouldShowEndpointSection {
          endpointSection
        }

        directorySection

        // Configuration card — model + autonomy grouped
        configurationCard

        // Error display
        if let error = errorMessage {
          errorBanner(error)
        }
      }
      .padding(Spacing.xl)

      Spacer(minLength: 0)

      Divider()
        .overlay(Color.surfaceBorder)

      // Footer
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
      refreshEndpointData()
      if selectedModel.isEmpty {
        selectedModel = defaultModelSelection
      }
    }
    .onChange(of: selectedEndpointId) { _, _ in
      selectedPath = ""
      selectedModel = ""
      normalizeEndpointSelection()
      refreshEndpointData()
    }
    .onChange(of: endpointAppState.codexModels.count) { _, _ in
      if selectedModel.isEmpty || !modelOptions.contains(where: { $0.model == selectedModel }) {
        selectedModel = defaultModelSelection
      }
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: Spacing.md) {
      // Codex brand icon
      Circle()
        .fill(Color.providerCodex.opacity(OpacityTier.light))
        .frame(width: 32, height: 32)
        .overlay(
          Image(systemName: "plus.circle.fill")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.providerCodex)
        )

      Text("New Codex Session")
        .font(.system(size: TypeScale.title, weight: .semibold))
        .foregroundStyle(Color.textPrimary)

      Spacer()

      // Inline auth status when connected
      if let account = endpointAppState.codexAccount {
        connectedBadge(account)
      }

      Button {
        dismiss()
      } label: {
        Image(systemName: "xmark.circle.fill")
          .font(.system(size: 18))
          .foregroundStyle(Color.textQuaternary)
      }
      .buttonStyle(.plain)
      #if !os(iOS)
        .onHover { hovering in
          if hovering {
            NSCursor.pointingHand.push()
          } else {
            NSCursor.pop()
          }
        }
      #endif
    }
    .padding(.horizontal, Spacing.xl)
    .padding(.vertical, Spacing.lg)
  }

  // MARK: - Auth Gate (only when NOT connected)

  private var authGateSection: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      HStack(spacing: Spacing.sm) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 11))
          .foregroundStyle(Color.statusPermission)

        Text("Connect your ChatGPT account to create sessions")
          .font(.system(size: TypeScale.body, weight: .medium))
          .foregroundStyle(Color.textSecondary)
      }

      HStack(spacing: Spacing.sm) {
        if endpointAppState.codexLoginInProgress {
          Button {
            endpointAppState.cancelCodexChatgptLogin()
          } label: {
            Label("Cancel", systemImage: "xmark.circle")
              .font(.system(size: TypeScale.body, weight: .semibold))
          }
          .buttonStyle(.bordered)

          HStack(spacing: Spacing.sm) {
            ProgressView()
              .controlSize(.small)
            Text("Waiting for browser…")
              .font(.system(size: TypeScale.caption))
              .foregroundStyle(Color.textTertiary)
          }
        } else {
          Button {
            endpointAppState.startCodexChatgptLogin()
          } label: {
            Label("Sign in with ChatGPT", systemImage: "sparkles")
              .font(.system(size: TypeScale.body, weight: .semibold))
          }
          .buttonStyle(.borderedProminent)
          .tint(Color.accent)
        }
      }

      if let authError = endpointAppState.codexAuthError, !authError.isEmpty {
        Text(authError)
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.statusPermission)
      }
    }
    .padding(Spacing.lg)
    .background(Color.statusPermission.opacity(OpacityTier.tint), in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .stroke(Color.statusPermission.opacity(OpacityTier.light), lineWidth: 1)
    )
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

  // MARK: - Configuration Card (Model + Autonomy)

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

        if !selectedModel.isEmpty {
          Picker("Model", selection: $selectedModel) {
            ForEach(modelOptions.filter { !$0.model.isEmpty }, id: \.id) { model in
              Text(model.displayName).tag(model.model)
            }
          }
          .pickerStyle(.menu)
          .labelsHidden()
          .fixedSize()
        } else {
          ProgressView()
            .controlSize(.small)
        }
      }
      .padding(.horizontal, Spacing.lg)
      .padding(.vertical, Spacing.md)

      Divider()
        .padding(.horizontal, Spacing.lg)

      // Autonomy row — unified selector design
      VStack(alignment: .leading, spacing: Spacing.sm) {
        HStack {
          HStack(spacing: Spacing.sm) {
            Image(systemName: selectedAutonomy.icon)
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(selectedAutonomy.color)
            Text("Autonomy")
              .font(.system(size: TypeScale.body, weight: .medium))
              .foregroundStyle(Color.textSecondary)
          }

          Spacer()

          CompactAutonomySelector(selection: $selectedAutonomy)
        }

        // Inline description — flows naturally from selector
        HStack(alignment: .top, spacing: Spacing.sm) {
          // Subtle indicator line
          Capsule()
            .fill(selectedAutonomy.color.opacity(0.4))
            .frame(width: 2, height: 20)
            .padding(.top, 2)

          VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(spacing: Spacing.sm) {
              Text(selectedAutonomy.displayName)
                .font(.system(size: TypeScale.body, weight: .semibold))
                .foregroundStyle(selectedAutonomy.color)

              if selectedAutonomy.isDefault {
                Text("DEFAULT")
                  .font(.system(size: 7, weight: .bold, design: .rounded))
                  .foregroundStyle(Color.textSecondary)
                  .padding(.horizontal, 5)
                  .padding(.vertical, 1.5)
                  .background(Color.textSecondary.opacity(OpacityTier.light), in: Capsule())
              }
            }

            Text(selectedAutonomy.description)
              .font(.system(size: TypeScale.caption))
              .foregroundStyle(Color.textTertiary)
              .fixedSize(horizontal: false, vertical: true)

            // Metadata badges
            HStack(spacing: Spacing.sm) {
              HStack(spacing: Spacing.xxs) {
                Image(systemName: selectedAutonomy.approvalBehavior
                  .contains("Never") ? "hand.raised.slash" : "hand.raised.fill")
                  .font(.system(size: 8))
                Text(selectedAutonomy.approvalBehavior)
                  .font(.system(size: TypeScale.micro, weight: .medium))
              }

              HStack(spacing: Spacing.xxs) {
                Image(systemName: selectedAutonomy.isSandboxed ? "shield.fill" : "shield.slash")
                  .font(.system(size: 8))
                Text(selectedAutonomy.isSandboxed ? "Sandboxed" : "No sandbox")
                  .font(.system(size: TypeScale.micro, weight: .medium))
              }
              .foregroundStyle(selectedAutonomy.isSandboxed ? Color.textQuaternary : Color.autonomyOpen.opacity(0.7))
            }
            .foregroundStyle(Color.textQuaternary)
            .padding(.top, Spacing.xxs)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, Spacing.lg)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: selectedAutonomy)
      }
      .padding(.horizontal, Spacing.lg)
      .padding(.vertical, Spacing.md)
    }
    .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .stroke(Color.surfaceBorder, lineWidth: 1)
    )
  }

  // MARK: - Footer

  private var footer: some View {
    HStack(spacing: Spacing.md) {
      // Sign out (subtle, in footer when connected)
      if endpointAppState.codexAccount != nil {
        Button {
          endpointAppState.logoutCodexAccount()
        } label: {
          Text("Sign Out")
            .font(.system(size: TypeScale.caption, weight: .medium))
            .foregroundStyle(Color.textQuaternary)
        }
        .buttonStyle(.plain)
        #if !os(iOS)
          .onHover { hovering in
            if hovering {
              NSCursor.pointingHand.push()
            } else {
              NSCursor.pop()
            }
          }
        #endif
      }

      Spacer()

      Button("Cancel") {
        dismiss()
      }
      .buttonStyle(.bordered)
      .tint(Color.textTertiary)
      .keyboardShortcut(.escape, modifiers: [])

      Button {
        createSession()
      } label: {
        if isCreating {
          HStack(spacing: Spacing.sm) {
            ProgressView()
              .controlSize(.small)
            Text("Launch")
              .font(.system(size: TypeScale.body, weight: .semibold))
          }
          .frame(minWidth: 90)
        } else {
          HStack(spacing: Spacing.sm) {
            Image(systemName: "paperplane.fill")
              .font(.system(size: 12, weight: .semibold))
            Text("Launch")
              .font(.system(size: TypeScale.body, weight: .semibold))
          }
          .frame(minWidth: 90)
        }
      }
      .buttonStyle(.borderedProminent)
      .tint(Color.providerCodex)
      .disabled(!canCreateSession)
      .keyboardShortcut(.return, modifiers: .command)
    }
    .padding(.horizontal, Spacing.xl)
    .padding(.vertical, Spacing.lg)
  }

  // MARK: - Helpers

  private func connectedBadge(_ account: ServerCodexAccount) -> some View {
    HStack(spacing: Spacing.sm) {
      switch account {
        case .apiKey:
          HStack(spacing: Spacing.xs) {
            Circle()
              .fill(Color.providerCodex)
              .frame(width: 6, height: 6)
            Text("API Key")
              .font(.system(size: TypeScale.caption, weight: .medium))
              .foregroundStyle(Color.textTertiary)
          }

        case let .chatgpt(email, planType):
          HStack(spacing: Spacing.xs) {
            Circle()
              .fill(Color.providerCodex)
              .frame(width: 6, height: 6)

            if let email {
              Text(email)
                .font(.system(size: TypeScale.caption, weight: .medium))
                .foregroundStyle(Color.textTertiary)
                .lineLimit(1)
            }

            if let planType {
              Text(planType.uppercased())
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(Color.providerCodex)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.providerCodex.opacity(OpacityTier.light), in: Capsule())
            }
          }
      }
    }
  }

  private func errorBanner(_ message: String) -> some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 11))
        .foregroundStyle(Color.statusPermission)
      Text(message)
        .font(.system(size: TypeScale.caption))
        .foregroundStyle(Color.textSecondary)
    }
    .padding(Spacing.md)
    .background(Color.statusPermission.opacity(OpacityTier.tint), in: RoundedRectangle(cornerRadius: Radius.md))
  }

  // MARK: - Actions

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

  private func refreshEndpointData() {
    endpointAppState.refreshCodexModels()
    endpointAppState.refreshCodexAccount()
  }

  private func createSession() {
    guard !selectedPath.isEmpty, !selectedModel.isEmpty else { return }

    endpointAppState.createSession(
      cwd: selectedPath,
      model: selectedModel,
      approvalPolicy: selectedAutonomy.approvalPolicy,
      sandboxMode: selectedAutonomy.sandboxMode
    )
    dismiss()
  }
}

// MARK: - Compact Autonomy Selector

/// Horizontal pill selector for autonomy levels.
/// Refined circular buttons with smooth interactions.
private struct CompactAutonomySelector: View {
  @Binding var selection: AutonomyLevel
  @State private var hoveredLevel: AutonomyLevel?

  private let levels = AutonomyLevel.allCases

  var body: some View {
    HStack(spacing: Spacing.sm) {
      ForEach(levels) { level in
        AutonomyLevelButton(
          level: level,
          isActive: level == selection,
          isHovered: hoveredLevel == level && level != selection,
          onTap: {
            selection = level
            #if os(macOS)
              NSHapticFeedbackManager.defaultPerformer.perform(
                .alignment,
                performanceTime: .default
              )
            #endif
          },
          onHover: { hovering in
            hoveredLevel = hovering ? level : nil
          }
        )
      }
    }
    #if !os(iOS)
      .onHover { hovering in
        if hovering {
          NSCursor.pointingHand.push()
        } else {
          NSCursor.pop()
          hoveredLevel = nil
        }
      }
    #endif
      .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hoveredLevel)
      .animation(.spring(response: 0.3, dampingFraction: 0.7), value: selection)
  }
}

// MARK: - Autonomy Level Button

private struct AutonomyLevelButton: View {
  let level: AutonomyLevel
  let isActive: Bool
  let isHovered: Bool
  let onTap: () -> Void
  let onHover: (Bool) -> Void

  var body: some View {
    Button(action: onTap) {
      buttonContent
    }
    .buttonStyle(.plain)
    #if !os(iOS)
      .onHover(perform: onHover)
      .help(level.displayName)
    #endif
      .contentShape(Circle())
  }

  @ViewBuilder
  private var buttonContent: some View {
    let iconColor = isActive ? Color.backgroundSecondary : (isHovered ? level.color : level.color.opacity(0.6))
    let shadowColor = isActive ? level.color.opacity(0.4) : Color.clear
    let scale = isActive ? 1.05 : 1.0

    Image(systemName: level.icon)
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(iconColor)
      .frame(width: 30, height: 30)
      .background(backgroundCircle)
      .overlay(strokeCircle)
      .shadow(color: shadowColor, radius: 6, y: 2)
      .scaleEffect(scale)
  }

  @ViewBuilder
  private var backgroundCircle: some View {
    if isActive {
      Circle().fill(level.color.gradient)
    } else if isHovered {
      Circle().fill(level.color.opacity(OpacityTier.light))
    } else {
      Circle().fill(Color.clear)
    }
  }

  @ViewBuilder
  private var strokeCircle: some View {
    let strokeColor = isActive ? Color.clear : (isHovered ? level.color.opacity(OpacityTier.strong) : level.color.opacity(0.3))
    let strokeWidth: CGFloat = isActive ? 0 : (isHovered ? 1.5 : 1)

    Circle().stroke(strokeColor, lineWidth: strokeWidth)
  }
}

#Preview {
  NewCodexSessionSheet()
    .environment(ServerAppState())
    .environment(ServerRuntimeRegistry.shared)
}
