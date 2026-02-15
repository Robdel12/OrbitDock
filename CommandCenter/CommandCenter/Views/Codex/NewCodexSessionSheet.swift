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
        codexAuthSection

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
            ForEach(modelOptions.filter { !$0.model.isEmpty }, id: \.id) { model in
              Text(model.displayName).tag(model.model)
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

          InlineAutonomyPicker(selection: $selectedAutonomy)
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

        if requiresLogin {
          HStack(spacing: 8) {
            Image(systemName: "lock.shield")
              .foregroundStyle(Color.statusPermission)
            Text("Sign in with ChatGPT to create Codex sessions.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .padding(.top, 4)
        }
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
    .frame(width: 450, height: 680)
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

  @ViewBuilder
  private var codexAuthSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Image(systemName: "person.crop.circle.badge.checkmark")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(Color.accent)
        Text("Codex Account")
          .font(.system(size: 13, weight: .semibold))
        Spacer()
        authStateBadge
      }

      switch serverState.codexAccount {
        case .apiKey?:
          Text("Using API key auth. ChatGPT subscription limits won’t be shown.")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)

        case let .chatgpt(email, planType)?:
          VStack(alignment: .leading, spacing: 6) {
            if let email {
              Text(email)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
            } else {
              Text("Signed in with ChatGPT")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
            }
            if let planType {
              Text(planType.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.accent)
            }
          }

        case .none:
          Text("Connect your ChatGPT account to unlock direct Codex sessions in OrbitDock.")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
      }

      HStack(spacing: 10) {
        if serverState.codexLoginInProgress {
          Button {
            serverState.cancelCodexChatgptLogin()
          } label: {
            Label("Cancel Sign-In", systemImage: "xmark.circle")
              .font(.system(size: 12, weight: .semibold))
          }
          .buttonStyle(.bordered)
        } else {
          Button {
            serverState.startCodexChatgptLogin()
          } label: {
            Label("Sign in with ChatGPT", systemImage: "sparkles")
              .font(.system(size: 12, weight: .semibold))
          }
          .buttonStyle(.borderedProminent)
          .tint(Color.accent)
        }

        if serverState.codexAccount != nil {
          Button {
            serverState.logoutCodexAccount()
          } label: {
            Text("Sign Out")
              .font(.system(size: 12, weight: .semibold))
          }
          .buttonStyle(.bordered)
        }

        Spacer()

        if serverState.codexLoginInProgress {
          HStack(spacing: 6) {
            ProgressView()
              .controlSize(.small)
            Text("Waiting for browser completion…")
              .font(.system(size: 11))
              .foregroundStyle(.secondary)
          }
        }
      }

      if let authError = serverState.codexAuthError, !authError.isEmpty {
        HStack(spacing: 8) {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 11))
            .foregroundStyle(Color.statusPermission)
          Text(authError)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color.backgroundTertiary)
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.accent.opacity(0.25), lineWidth: 1)
        )
    )
  }

  @ViewBuilder
  private var authStateBadge: some View {
    if serverState.codexLoginInProgress {
      Text("SIGNING IN")
        .font(.system(size: 10, weight: .bold, design: .rounded))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.statusWorking.opacity(0.2), in: Capsule())
        .foregroundStyle(Color.statusWorking)
    } else if serverState.codexAccount == nil {
      Text("NOT CONNECTED")
        .font(.system(size: 10, weight: .bold, design: .rounded))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.statusPermission.opacity(0.16), in: Capsule())
        .foregroundStyle(Color.statusPermission)
    } else {
      Text("CONNECTED")
        .font(.system(size: 10, weight: .bold, design: .rounded))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.statusSuccess.opacity(0.2), in: Capsule())
        .foregroundStyle(Color.statusSuccess)
    }
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

#Preview {
  NewCodexSessionSheet()
    .environment(ServerAppState())
}
