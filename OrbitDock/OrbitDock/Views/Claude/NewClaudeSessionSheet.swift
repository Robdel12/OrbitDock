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
  @State private var selectedPathIsGit: Bool = true
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
  @State private var useWorktree = false
  @State private var worktreeBranch = ""
  @State private var worktreeBaseBranch = ""
  @State private var showGitInitConfirmation = false
  @State private var worktreeError: String?

  private var canCreateSession: Bool {
    let pathReady = !selectedPath.isEmpty
    let worktreeReady = !useWorktree || !worktreeBranch.trimmingCharacters(in: .whitespaces).isEmpty
    return pathReady && worktreeReady && !isCreating && isEndpointConnected
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

  private var formSectionSpacing: CGFloat {
    #if os(iOS)
      Spacing.lg
    #else
      Spacing.xl
    #endif
  }

  var body: some View {
    VStack(spacing: 0) {
      header

      Divider()
        .overlay(Color.surfaceBorder)

      formContent

      Divider()
        .overlay(Color.surfaceBorder)

      footer
    }
    #if os(iOS)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    #else
    .frame(minWidth: 420, idealWidth: 500, maxWidth: 580)
    #endif
    .background(Color.backgroundSecondary)
    .onAppear {
      if let primaryEndpointId = runtimeRegistry.primaryEndpointId,
         selectableEndpoints.contains(where: { $0.id == primaryEndpointId })
      {
        selectedEndpointId = primaryEndpointId
      }
      normalizeEndpointSelection()
      // Load cached models (populated when Claude sessions are created)
      endpointAppState.refreshClaudeModels()
    }
    .onChange(of: selectedPath) { _, _ in
      useWorktree = false
      worktreeBranch = ""
      worktreeBaseBranch = ""
      worktreeError = nil
    }
    .onChange(of: selectedEndpointId) { _, _ in
      selectedPath = ""
      selectedModelId = ""
      customModelInput = ""
      useCustomModel = false
      normalizeEndpointSelection()
      endpointAppState.refreshClaudeModels()
    }
    .onChange(of: availableModels.count) { _, _ in
      // When models arrive, update selection
      if availableModels.isEmpty {
        useCustomModel = true
      } else if selectedModelId.isEmpty || !availableModels.contains(where: { $0.value == selectedModelId }) {
        selectedModelId = availableModels.first?.value ?? ""
        useCustomModel = false
      }
    }
  }

  @ViewBuilder
  private var formContent: some View {
    #if os(iOS)
      ScrollView(showsIndicators: false) {
        formSections
          .padding(.horizontal, Spacing.lg)
          .padding(.vertical, Spacing.lg)
          .padding(.bottom, Spacing.sm)
      }
    #else
      VStack {
        formSections
          .padding(Spacing.xl)
        Spacer(minLength: 0)
      }
    #endif
  }

  private var formSections: some View {
    VStack(alignment: .leading, spacing: formSectionSpacing) {
      if shouldShowEndpointSection {
        endpointSection
      }
      directorySection
      if !selectedPath.isEmpty {
        worktreeSection
      }
      configurationCard
      toolRestrictionsCard
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: - Header

  private var header: some View {
    #if os(iOS)
      HStack(spacing: Spacing.md) {
        headerIcon

        Text("New Claude Session")
          .font(.system(size: TypeScale.large, weight: .semibold))
          .foregroundStyle(Color.textPrimary)
          .lineLimit(1)
          .minimumScaleFactor(0.9)

        Spacer()

        closeButton
      }
      .padding(.horizontal, Spacing.lg)
      .padding(.vertical, Spacing.md)
    #else
      HStack(spacing: Spacing.md) {
        headerIcon

        Text("New Claude Session")
          .font(.system(size: TypeScale.title, weight: .semibold))
          .foregroundStyle(Color.textPrimary)

        Spacer()

        closeButton
      }
      .padding(.horizontal, Spacing.xl)
      .padding(.vertical, Spacing.lg)
    #endif
  }

  private var headerIcon: some View {
    Circle()
      .fill(Color.providerClaude.opacity(OpacityTier.light))
      .frame(width: 32, height: 32)
      .overlay(
        Image(systemName: "plus.circle.fill")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(Color.providerClaude)
      )
  }

  private var closeButton: some View {
    Button {
      dismiss()
    } label: {
      Image(systemName: "xmark.circle.fill")
        .font(.system(size: 18))
        .foregroundStyle(Color.textQuaternary)
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
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
      RemoteProjectPicker(
        selectedPath: $selectedPath,
        selectedPathIsGit: $selectedPathIsGit,
        endpointId: selectedEndpointId
      )
    #else
      ProjectPicker(
        selectedPath: $selectedPath,
        selectedPathIsGit: $selectedPathIsGit,
        endpointId: selectedEndpointId
      )
    #endif
  }

  // MARK: - Worktree Section

  private var worktreeSection: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Toggle row
      HStack(spacing: Spacing.sm) {
        Image(systemName: "arrow.triangle.branch")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(useWorktree ? Color.accent : Color.textTertiary)

        Text("Use Worktree")
          .font(.system(size: TypeScale.body, weight: .medium))
          .foregroundStyle(Color.textSecondary)

        Spacer()

        Toggle("", isOn: $useWorktree)
          .labelsHidden()
          .toggleStyle(.switch)
          .controlSize(.small)
      }
      .padding(.horizontal, Spacing.lg)
      .padding(.vertical, Spacing.md)

      if useWorktree {
        Divider()
          .padding(.horizontal, Spacing.lg)

        VStack(alignment: .leading, spacing: Spacing.md) {
          VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Branch Name")
              .font(.system(size: TypeScale.caption, weight: .semibold))
              .foregroundStyle(Color.textSecondary)
            TextField("feat/my-feature", text: $worktreeBranch)
              .textFieldStyle(.roundedBorder)
              .font(.system(size: TypeScale.body, design: .monospaced))
          }

          VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
              Text("Base Branch")
                .font(.system(size: TypeScale.caption, weight: .semibold))
                .foregroundStyle(Color.textSecondary)
              Text("optional")
                .font(.system(size: TypeScale.micro))
                .foregroundStyle(Color.textQuaternary)
            }
            TextField("main", text: $worktreeBaseBranch)
              .textFieldStyle(.roundedBorder)
              .font(.system(size: TypeScale.body, design: .monospaced))
          }

          // Preview path
          let branchTrimmed = worktreeBranch.trimmingCharacters(in: .whitespaces)
          if !branchTrimmed.isEmpty {
            HStack(spacing: Spacing.xs) {
              Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 10))
                .foregroundStyle(Color.textQuaternary)
              Text("\(selectedPath)/.orbitdock-worktrees/\(branchTrimmed)/")
                .font(.system(size: TypeScale.micro, design: .monospaced))
                .foregroundStyle(Color.textQuaternary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
          }

          if let error = worktreeError {
            HStack(spacing: Spacing.xs) {
              Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color.statusPermission)
              Text(error)
                .font(.system(size: TypeScale.caption))
                .foregroundStyle(Color.statusPermission)
            }
          }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .stroke(Color.surfaceBorder, lineWidth: 1)
    )
    .animation(Motion.bouncy, value: useWorktree)
    .onChange(of: useWorktree) { _, isOn in
      if isOn, !selectedPathIsGit {
        // Directory isn't a git repo — prompt to init
        useWorktree = false
        showGitInitConfirmation = true
      }
      worktreeError = nil
    }
    .alert("Initialize Git Repository?", isPresented: $showGitInitConfirmation) {
      Button("Initialize") {
        initGitAndEnableWorktree()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This directory is not a git repository. Initialize one to use worktrees?")
    }
  }

  private func initGitAndEnableWorktree() {
    guard let connection = runtimeRegistry.connection(for: selectedEndpointId) else { return }
    isCreating = true
    Task { @MainActor in
      defer { isCreating = false }
      do {
        try await connection.gitInit(path: selectedPath)
        selectedPathIsGit = true
        useWorktree = true
      } catch {
        worktreeError = "Failed to initialize git: \(error.localizedDescription)"
      }
    }
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

      // Permission mode row — unified selector design
      VStack(alignment: .leading, spacing: Spacing.sm) {
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

        // Inline description — flows naturally from selector
        HStack(alignment: .top, spacing: Spacing.sm) {
          // Subtle indicator line
          Capsule()
            .fill(selectedPermissionMode.color.opacity(0.4))
            .frame(width: 2, height: 20)
            .padding(.top, Spacing.xxs)

          VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(spacing: Spacing.sm) {
              Text(selectedPermissionMode.displayName)
                .font(.system(size: TypeScale.body, weight: .semibold))
                .foregroundStyle(selectedPermissionMode.color)

              if selectedPermissionMode.isDefault {
                Text("DEFAULT")
                  .font(.system(size: 7, weight: .bold, design: .rounded))
                  .foregroundStyle(Color.textSecondary)
                  .padding(.horizontal, 5)
                  .padding(.vertical, 1.5)
                  .background(Color.textSecondary.opacity(OpacityTier.light), in: Capsule())
              }
            }

            Text(selectedPermissionMode.description)
              .font(.system(size: TypeScale.caption))
              .foregroundStyle(Color.textTertiary)
              .fixedSize(horizontal: false, vertical: true)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, Spacing.lg)
        .animation(Motion.bouncy, value: selectedPermissionMode)
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

  // MARK: - Tool Restrictions Card

  private var toolRestrictionsCard: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(Motion.bouncy) {
          showToolConfig.toggle()
        }
      } label: {
        HStack(spacing: Spacing.sm) {
          Circle()
            .fill(Color.textQuaternary.opacity(OpacityTier.light))
            .frame(width: 20, height: 20)
            .overlay(
              Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.textTertiary)
            )

          Text("Tool Restrictions")
            .font(.system(size: TypeScale.body, weight: .medium))
            .foregroundStyle(Color.textSecondary)

          Text("OPTIONAL")
            .font(.system(size: 7, weight: .bold, design: .rounded))
            .foregroundStyle(Color.textTertiary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Color.textTertiary.opacity(OpacityTier.light), in: Capsule())

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
      #if !os(iOS)
        .onHover { hovering in
          if hovering {
            NSCursor.pointingHand.push()
          } else {
            NSCursor.pop()
          }
        }
      #endif

      if showToolConfig {
        Divider()
          .padding(.horizontal, Spacing.lg)

        VStack(alignment: .leading, spacing: Spacing.md) {
          VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
              Text("Allowed Tools")
                .font(.system(size: TypeScale.caption, weight: .semibold))
                .foregroundStyle(Color.textSecondary)
              Text("•")
                .font(.system(size: TypeScale.micro))
                .foregroundStyle(Color.textQuaternary)
              Text("Comma-separated list")
                .font(.system(size: TypeScale.micro))
                .foregroundStyle(Color.textTertiary)
            }
            TextField("e.g. Read, Glob, Bash(git:*)", text: $allowedToolsText)
              .textFieldStyle(.roundedBorder)
              .font(.system(size: TypeScale.caption, design: .monospaced))
          }

          VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
              Text("Disallowed Tools")
                .font(.system(size: TypeScale.caption, weight: .semibold))
                .foregroundStyle(Color.textSecondary)
              Text("•")
                .font(.system(size: TypeScale.micro))
                .foregroundStyle(Color.textQuaternary)
              Text("Comma-separated list")
                .font(.system(size: TypeScale.micro))
                .foregroundStyle(Color.textTertiary)
            }
            TextField("e.g. Write, Edit", text: $disallowedToolsText)
              .textFieldStyle(.roundedBorder)
              .font(.system(size: TypeScale.caption, design: .monospaced))
          }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
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

    let branch = worktreeBranch.trimmingCharacters(in: .whitespaces)
    if useWorktree, !branch.isEmpty {
      // Async flow: create worktree first, then launch session in it
      isCreating = true
      worktreeError = nil
      guard let connection = runtimeRegistry.connection(for: selectedEndpointId) else { return }
      Task { @MainActor in
        do {
          let baseBranch = worktreeBaseBranch.trimmingCharacters(in: .whitespaces)
          let worktree = try await connection.createWorktreeAsync(
            repoPath: selectedPath,
            branchName: branch,
            baseBranch: baseBranch.isEmpty ? nil : baseBranch
          )
          endpointAppState.createClaudeSession(
            cwd: worktree.worktreePath,
            model: resolvedModel,
            permissionMode: selectedPermissionMode == .default ? nil : selectedPermissionMode.rawValue,
            allowedTools: parseToolList(allowedToolsText),
            disallowedTools: parseToolList(disallowedToolsText),
            effort: selectedEffort
          )
          dismiss()
        } catch {
          isCreating = false
          worktreeError = error.localizedDescription
        }
      }
    } else {
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
}

// MARK: - Compact Permission Selector

/// Horizontal pill selector for Claude permission modes.
/// Refined circular buttons with smooth interactions.
private struct CompactClaudePermissionSelector: View {
  @Binding var selection: ClaudePermissionMode
  @State private var hoveredMode: ClaudePermissionMode?

  private let modes = ClaudePermissionMode.allCases

  var body: some View {
    HStack(spacing: Spacing.sm) {
      ForEach(modes) { mode in
        PermissionModeButton(
          mode: mode,
          isActive: mode == selection,
          isHovered: hoveredMode == mode && mode != selection,
          onTap: {
            selection = mode
            #if os(macOS)
              NSHapticFeedbackManager.defaultPerformer.perform(
                .alignment,
                performanceTime: .default
              )
            #endif
          },
          onHover: { hovering in
            hoveredMode = hovering ? mode : nil
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
        hoveredMode = nil
      }
    }
    #endif
    .animation(Motion.bouncy, value: hoveredMode)
    .animation(Motion.bouncy, value: selection)
  }
}

// MARK: - Permission Mode Button

private struct PermissionModeButton: View {
  let mode: ClaudePermissionMode
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
      .help(mode.displayName)
    #endif
      .contentShape(Circle())
  }

  @ViewBuilder
  private var buttonContent: some View {
    let iconColor = isActive ? Color.backgroundSecondary : (isHovered ? mode.color : mode.color.opacity(0.6))
    let scale = isActive ? 1.05 : 1.0

    Image(systemName: mode.icon)
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(iconColor)
      .frame(width: 30, height: 30)
      .background(backgroundCircle)
      .overlay(strokeCircle)
      .themeShadow(Shadow.glow(color: isActive ? mode.color : .clear))
      .scaleEffect(scale)
  }

  @ViewBuilder
  private var backgroundCircle: some View {
    if isActive {
      Circle().fill(mode.color.gradient)
    } else if isHovered {
      Circle().fill(mode.color.opacity(OpacityTier.light))
    } else {
      Circle().fill(Color.clear)
    }
  }

  @ViewBuilder
  private var strokeCircle: some View {
    let strokeColor = isActive ? Color
      .clear : (isHovered ? mode.color.opacity(OpacityTier.strong) : mode.color.opacity(0.3))
    let strokeWidth: CGFloat = isActive ? 0 : (isHovered ? 1.5 : 1)

    Circle().stroke(strokeColor, lineWidth: strokeWidth)
  }
}

#Preview {
  NewClaudeSessionSheet()
    .environment(ServerAppState())
    .environment(ServerRuntimeRegistry.shared)
}
