//
//  NewClaudeSessionSheet.swift
//  OrbitDock
//
//  Sheet for creating new direct Claude sessions.
//  Simpler than Codex — no auth flow needed, just directory + optional model.
//

import SwiftUI

private struct ClaudeModelOption: Identifiable, Hashable {
  let id: String
  let displayName: String
  let description: String
  let isDefault: Bool

  static let models: [ClaudeModelOption] = [
    ClaudeModelOption(
      id: "",
      displayName: "Default",
      description: "Uses server default (typically Sonnet)",
      isDefault: true
    ),
    ClaudeModelOption(
      id: "claude-sonnet-4-5-20250929",
      displayName: "Sonnet 4.5",
      description: "Fast, capable — best balance of speed and quality",
      isDefault: false
    ),
    ClaudeModelOption(
      id: "claude-opus-4-6",
      displayName: "Opus 4.6",
      description: "Most capable — complex tasks, deep reasoning",
      isDefault: false
    ),
    ClaudeModelOption(
      id: "claude-haiku-4-5-20251001",
      displayName: "Haiku 4.5",
      description: "Fastest — simple tasks, quick iterations",
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
      // Header
      HStack {
        Text("New Claude Session")
          .font(.headline)

        Spacer()

        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 18))
            .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
      }
      .padding()

      Divider()

      // Content
      VStack(alignment: .leading, spacing: 20) {
        // Directory picker
        VStack(alignment: .leading, spacing: 8) {
          Text("Project Directory")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)

          HStack(spacing: 12) {
            TextField("Select a directory...", text: $selectedPath)
              .textFieldStyle(.roundedBorder)
              .disabled(true)

            Button("Browse") {
              selectDirectory()
            }
            .buttonStyle(.bordered)
          }
        }

        // Model picker
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text("Model")
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(.secondary)

            Spacer()

            Button {
              useCustomModel.toggle()
              if !useCustomModel {
                customModelInput = ""
              }
            } label: {
              Text(useCustomModel ? "Use Picker" : "Custom")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accent)
            }
            .buttonStyle(.plain)
          }

          if useCustomModel {
            TextField("e.g. claude-sonnet-4-5-20250929", text: $customModelInput)
              .textFieldStyle(.roundedBorder)
          } else {
            VStack(spacing: 6) {
              ForEach(ClaudeModelOption.models) { option in
                modelRow(option)
              }
            }
          }
        }

        Spacer()
      }
      .padding()

      Divider()

      // Footer
      HStack {
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
              .frame(width: 60)
          } else {
            Text("Create")
              .frame(width: 60)
          }
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.accent)
        .disabled(!canCreateSession)
        .keyboardShortcut(.return, modifiers: .command)
      }
      .padding()
    }
    .frame(width: 450, height: 460)
    .background(Color.backgroundSecondary)
  }

  private func modelRow(_ option: ClaudeModelOption) -> some View {
    let isSelected = selectedModelId == option.id

    return Button {
      selectedModelId = option.id
    } label: {
      HStack(spacing: 10) {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(isSelected ? AnyShapeStyle(Color.accent) : AnyShapeStyle(.tertiary))

        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(option.displayName)
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(.primary)

            if option.isDefault {
              Text("DEFAULT")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(Color.accent)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.accent.opacity(0.15), in: Capsule())
            }
          }

          Text(option.description)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }

        Spacer()
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(isSelected ? Color.accent.opacity(0.08) : Color.backgroundTertiary.opacity(0.5))
          .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .stroke(isSelected ? Color.accent.opacity(0.3) : Color.clear, lineWidth: 1)
          )
      )
    }
    .buttonStyle(.plain)
  }

  // MARK: - Actions

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

  private func createSession() {
    guard !selectedPath.isEmpty else { return }
    serverState.createClaudeSession(cwd: selectedPath, model: resolvedModel)
    dismiss()
  }
}

#Preview {
  NewClaudeSessionSheet()
    .environment(ServerAppState())
}
