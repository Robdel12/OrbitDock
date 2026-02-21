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

  @State private var selectedPath: String = ""
  @State private var selectedModel: String = ""
  @State private var selectedAutonomy: AutonomyLevel = .autonomous
  @State private var isCreating = false
  @State private var errorMessage: String?

  private var modelOptions: [ServerCodexModelOption] {
    serverState.codexModels
  }

  private var requiresLogin: Bool {
    serverState.codexRequiresOpenAIAuth && serverState.codexAccount == nil
  }

  private var canCreateSession: Bool {
    !selectedPath.isEmpty && !selectedModel.isEmpty && !isCreating && !requiresLogin
  }

  private var defaultModelSelection: String {
    if let model = modelOptions.first(where: { $0.isDefault && !$0.model.isEmpty })?.model {
      return model
    }
    return modelOptions.first(where: { !$0.model.isEmpty })?.model ?? ""
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
        if serverState.codexAccount == nil {
          authGateSection
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
      serverState.refreshCodexModels()
      serverState.refreshCodexAccount()
      if selectedModel.isEmpty {
        selectedModel = defaultModelSelection
      }
    }
    .onChange(of: serverState.codexModels.count) { _, _ in
      if selectedModel.isEmpty || !modelOptions.contains(where: { $0.model == selectedModel }) {
        selectedModel = defaultModelSelection
      }
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: Spacing.md) {
      Image(systemName: "plus.circle.fill")
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(Color.providerCodex)

      Text("New Codex Session")
        .font(.system(size: TypeScale.title, weight: .semibold))
        .foregroundStyle(Color.textPrimary)

      Spacer()

      // Inline auth status when connected
      if let account = serverState.codexAccount {
        connectedBadge(account)
      }

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
        if serverState.codexLoginInProgress {
          Button {
            serverState.cancelCodexChatgptLogin()
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
            serverState.startCodexChatgptLogin()
          } label: {
            Label("Sign in with ChatGPT", systemImage: "sparkles")
              .font(.system(size: TypeScale.body, weight: .semibold))
          }
          .buttonStyle(.borderedProminent)
          .tint(Color.accent)
        }
      }

      if let authError = serverState.codexAuthError, !authError.isEmpty {
        Text(authError)
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.statusPermission)
      }
    }
    .padding(Spacing.lg)
    .background(Color.statusPermission.opacity(OpacityTier.tint), in: RoundedRectangle(cornerRadius: Radius.lg))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg)
        .stroke(Color.statusPermission.opacity(OpacityTier.light), lineWidth: 1)
    )
  }

  // MARK: - Directory

  private var directorySection: some View {
    #if os(iOS)
      RemoteProjectPicker(selectedPath: $selectedPath)
    #else
      macOSDirectorySection
    #endif
  }

  #if !os(iOS)
    private var macOSDirectorySection: some View {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        Text("Project Directory")
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.textTertiary)
          .textCase(.uppercase)
          .tracking(0.5)

        Button {
          selectDirectory()
        } label: {
          HStack(spacing: Spacing.md) {
            Image(systemName: "folder.fill")
              .font(.system(size: 14))
              .foregroundStyle(Color.providerCodex)

            if selectedPath.isEmpty {
              Text("Choose a project folder…")
                .font(.system(size: TypeScale.subhead))
                .foregroundStyle(Color.textQuaternary)
            } else {
              VStack(alignment: .leading, spacing: 2) {
                Text(URL(fileURLWithPath: selectedPath).lastPathComponent)
                  .font(.system(size: TypeScale.subhead, weight: .medium))
                  .foregroundStyle(Color.textPrimary)

                Text(shortenedPath(selectedPath))
                  .font(.system(size: TypeScale.caption, design: .monospaced))
                  .foregroundStyle(Color.textTertiary)
                  .lineLimit(1)
                  .truncationMode(.middle)
              }
            }

            Spacer()

            Text("Browse")
              .font(.system(size: TypeScale.body, weight: .medium))
              .foregroundStyle(Color.accent)
          }
          .padding(.horizontal, Spacing.lg)
          .padding(.vertical, Spacing.md)
          .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.lg))
          .overlay(
            RoundedRectangle(cornerRadius: Radius.lg)
              .stroke(Color.surfaceBorder, lineWidth: 1)
          )
        }
        .buttonStyle(.plain)
      }
    }
  #endif

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

        Picker("Model", selection: $selectedModel) {
          ForEach(modelOptions.filter { !$0.model.isEmpty }, id: \.id) { model in
            Text(model.displayName).tag(model.model)
          }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
      }
      .padding(.horizontal, Spacing.lg)
      .padding(.vertical, Spacing.md)

      Divider()
        .padding(.horizontal, Spacing.lg)

      // Autonomy row — selector + detail integrated
      VStack(alignment: .leading, spacing: Spacing.md) {
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

        // Selected level detail
        HStack(spacing: Spacing.sm) {
          RoundedRectangle(cornerRadius: 1.5)
            .fill(selectedAutonomy.color)
            .frame(width: 2)

          VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(spacing: Spacing.sm) {
              Text(selectedAutonomy.displayName)
                .font(.system(size: TypeScale.body, weight: .semibold))
                .foregroundStyle(selectedAutonomy.color)

              if selectedAutonomy.isDefault {
                Text("DEFAULT")
                  .font(.system(size: 7, weight: .bold, design: .rounded))
                  .foregroundStyle(Color.autonomyAutonomous)
                  .padding(.horizontal, 4)
                  .padding(.vertical, 1.5)
                  .background(Color.autonomyAutonomous.opacity(OpacityTier.light), in: Capsule())
              }
            }

            Text(selectedAutonomy.description)
              .font(.system(size: TypeScale.caption))
              .foregroundStyle(Color.textTertiary)

            HStack(spacing: Spacing.md) {
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
          }
        }
        .padding(Spacing.sm)
        .background(selectedAutonomy.color.opacity(OpacityTier.tint), in: RoundedRectangle(cornerRadius: Radius.md))
        .animation(.easeOut(duration: 0.15), value: selectedAutonomy)
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

  // MARK: - Footer

  private var footer: some View {
    HStack(spacing: Spacing.md) {
      // Sign out (subtle, in footer when connected)
      if serverState.codexAccount != nil {
        Button {
          serverState.logoutCodexAccount()
        } label: {
          Text("Sign Out")
            .font(.system(size: TypeScale.caption, weight: .medium))
            .foregroundStyle(Color.textQuaternary)
        }
        .buttonStyle(.plain)
      }

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

  private func shortenedPath(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path.hasPrefix(home) {
      return "~" + path.dropFirst(home.count)
    }
    return path
  }

  // MARK: - Actions

  #if !os(iOS)
    private func selectDirectory() {
      let panel = NSOpenPanel()
      panel.canChooseDirectories = true
      panel.canChooseFiles = false
      panel.allowsMultipleSelection = false
      panel.canCreateDirectories = false
      panel.prompt = "Select"
      panel.message = "Choose a project directory for the new Codex session"

      panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/Developer")

      if panel.runModal() == .OK, let url = panel.url {
        selectedPath = url.path
      }
    }
  #endif

  private func createSession() {
    guard !selectedPath.isEmpty, !selectedModel.isEmpty else { return }

    serverState.createSession(
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
/// Shows level icons as tappable pills with a color-coded active state.
/// Pair with the `autonomyDetail` section to show the selected level's info.
private struct CompactAutonomySelector: View {
  @Binding var selection: AutonomyLevel
  @State private var hoveredLevel: AutonomyLevel?

  private let levels = AutonomyLevel.allCases

  var body: some View {
    HStack(spacing: Spacing.xs) {
      ForEach(levels) { level in
        let isActive = level == selection
        let isHovered = hoveredLevel == level && !isActive

        Button {
          selection = level
        } label: {
          Image(systemName: level.icon)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(
              isActive
                ? Color.backgroundSecondary
                : isHovered
                ? level.color
                : level.color.opacity(0.5)
            )
            .frame(width: 28, height: 28)
            .background(
              Circle()
                .fill(
                  isActive
                    ? level.color
                    : isHovered
                    ? level.color.opacity(OpacityTier.light)
                    : Color.clear
                )
            )
            .overlay(
              Circle()
                .stroke(
                  isActive
                    ? Color.clear
                    : isHovered
                    ? level.color.opacity(OpacityTier.strong)
                    : level.color.opacity(OpacityTier.medium),
                  lineWidth: 1
                )
            )
            .shadow(color: isActive ? level.color.opacity(0.3) : .clear, radius: 4)
        }
        .buttonStyle(.plain)
        #if !os(iOS)
          .onHover { hovering in
            hoveredLevel = hovering ? level : nil
          }
          .help(level.displayName)
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
        hoveredLevel = nil
      }
    }
    #endif
    .animation(.easeOut(duration: 0.12), value: hoveredLevel)
    .animation(.easeOut(duration: 0.15), value: selection)
  }
}

#Preview {
  NewCodexSessionSheet()
    .environment(ServerAppState())
}
