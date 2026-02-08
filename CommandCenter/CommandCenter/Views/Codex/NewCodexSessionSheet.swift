//
//  NewCodexSessionSheet.swift
//  OrbitDock
//
//  Sheet for creating new direct Codex sessions.
//  Allows users to select a directory and optional model.
//

import SwiftUI

struct NewCodexSessionSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(ServerAppState.self) private var serverState

  @State private var selectedPath: String = ""
  @State private var selectedModel: CodexModel = .default
  @State private var selectedAutonomy: AutonomyLevel = .suggest
  @State private var isCreating = false
  @State private var errorMessage: String?

  var body: some View {
    VStack(spacing: 0) {
      // Header
      HStack {
        Text("New Codex Session")
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
          Text("Model")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)

          Picker("Model", selection: $selectedModel) {
            ForEach(CodexModel.allCases) { model in
              Text(model.displayName).tag(model)
            }
          }
          .pickerStyle(.menu)
          .labelsHidden()
        }

        // Autonomy picker
        VStack(alignment: .leading, spacing: 8) {
          Text("Autonomy")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)

          Picker("Autonomy", selection: $selectedAutonomy) {
            ForEach(AutonomyLevel.allCases) { level in
              Label(level.displayName, systemImage: level.icon)
                .tag(level)
            }
          }
          .pickerStyle(.segmented)
          .labelsHidden()

          HStack(spacing: 6) {
            Image(systemName: selectedAutonomy.icon)
              .font(.caption)
              .foregroundStyle(selectedAutonomy == .fullAccess ? Color.statusPermission : .secondary)

            Text(selectedAutonomy.description)
              .font(.caption)
              .foregroundStyle(selectedAutonomy == .fullAccess ? Color.statusPermission : .secondary)
          }
        }

        // Error message
        if let error = errorMessage {
          HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
            Text(error)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .padding(10)
          .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
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
        .disabled(selectedPath.isEmpty || isCreating)
        .keyboardShortcut(.return, modifiers: .command)
      }
      .padding()
    }
    .frame(width: 450, height: 400)
    .background(Color.backgroundSecondary)
  }

  // MARK: - Actions

  private func selectDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    panel.prompt = "Select"
    panel.message = "Choose a project directory for the new Codex session"

    // Start in home directory or last used location
    panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/Developer")

    if panel.runModal() == .OK, let url = panel.url {
      selectedPath = url.path
    }
  }

  private func createSession() {
    guard !selectedPath.isEmpty else { return }

    let model = selectedModel == .default ? nil : selectedModel.rawValue
    serverState.createSession(
      cwd: selectedPath,
      model: model,
      approvalPolicy: selectedAutonomy.approvalPolicy,
      sandboxMode: selectedAutonomy.sandboxMode
    )
    dismiss()
  }
}

#Preview {
  NewCodexSessionSheet()
    .environment(ServerAppState())
}
