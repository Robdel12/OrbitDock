//
//  NewClaudeSessionSheet.swift
//  OrbitDock
//
//  Sheet for creating new direct Claude sessions.
//  Matches the Codex sheet pattern — directory → config card → launch.
//

import SwiftUI

private struct ClaudeModelOption: Identifiable, Hashable {
  let id: String
  let displayName: String
  let isDefault: Bool

  static let models: [ClaudeModelOption] = [
    ClaudeModelOption(
      id: "claude-sonnet-4-5-20250929",
      displayName: "Sonnet 4.5",
      isDefault: true
    ),
    ClaudeModelOption(
      id: "claude-opus-4-6",
      displayName: "Opus 4.6",
      isDefault: false
    ),
    ClaudeModelOption(
      id: "claude-haiku-4-5-20251001",
      displayName: "Haiku 4.5",
      isDefault: false
    ),
  ]
}

struct NewClaudeSessionSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(ServerAppState.self) private var serverState

  @State private var selectedPath: String = ""
  @State private var selectedModelId: String = ""
  @State private var customModelInput: String = ""
  @State private var useCustomModel = false
  @State private var isCreating = false
  @State private var selectedPermissionMode: ClaudePermissionMode = .default
  @State private var allowedToolsText: String = ""
  @State private var disallowedToolsText: String = ""
  @State private var showToolConfig = false

  private var canCreateSession: Bool {
    !selectedPath.isEmpty && !isCreating
  }

  private var resolvedModel: String? {
    if useCustomModel {
      let trimmed = customModelInput.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    return selectedModelId.isEmpty ? nil : selectedModelId
  }

  var body: some View {
    VStack(spacing: 0) {
      header

      Divider()
        .overlay(Color.surfaceBorder)

      // Form content
      VStack(alignment: .leading, spacing: Spacing.xl) {
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
      if selectedModelId.isEmpty {
        selectedModelId = ClaudeModelOption.models.first(where: \.isDefault)?.id ?? ""
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
              .foregroundStyle(Color.providerClaude)

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
            ForEach(ClaudeModelOption.models) { model in
              Text(model.displayName).tag(model.id)
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

  // MARK: - Helpers

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
      panel.message = "Choose a project directory for the new Claude session"

      panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/Developer")

      if panel.runModal() == .OK, let url = panel.url {
        selectedPath = url.path
      }
    }
  #endif

  private func parseToolList(_ text: String) -> [String] {
    text.split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }

  private func createSession() {
    guard !selectedPath.isEmpty else { return }
    serverState.createClaudeSession(
      cwd: selectedPath,
      model: resolvedModel,
      permissionMode: selectedPermissionMode == .default ? nil : selectedPermissionMode.rawValue,
      allowedTools: parseToolList(allowedToolsText),
      disallowedTools: parseToolList(disallowedToolsText)
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
}
