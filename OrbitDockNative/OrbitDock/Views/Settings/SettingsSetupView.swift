import SwiftUI

struct SetupSettingsView: View {
  @Environment(SessionStore.self) private var serverState
  @State private var copied = false
  @State private var hooksConfigured: Bool? = nil

  private let hookForwardPath = "/Applications/OrbitDock.app/Contents/Resources/orbitdock"
  private let settingsPath = PlatformPaths.homeDirectory
    .appendingPathComponent(".claude/settings.json").path

  var body: some View {
    ScrollView {
      VStack(spacing: Spacing.xl) {
        SettingsSection(title: "CLAUDE CODE", icon: "terminal") {
          VStack(alignment: .leading, spacing: Spacing.lg_) {
            HStack {
              if let configured = hooksConfigured {
                if configured {
                  Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.feedbackPositive)
                  Text("Hooks configured")
                    .font(.system(size: TypeScale.body))
                } else {
                  Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(Color.statusPermission)
                  Text("Hooks not configured")
                    .font(.system(size: TypeScale.body))
                }
              } else {
                ProgressView()
                  .controlSize(.small)
                Text("Checking...")
                  .font(.system(size: TypeScale.body))
                  .foregroundStyle(Color.textSecondary)
              }
              Spacer()
            }

            Divider()
              .foregroundStyle(Color.panelBorder)

            VStack(alignment: .leading, spacing: Spacing.sm) {
              Text("Add hooks to ~/.claude/settings.json:")
                .font(.system(size: TypeScale.caption))
                .foregroundStyle(Color.textSecondary)

              HStack(spacing: Spacing.md_) {
                Button {
                  copyToClipboard()
                } label: {
                  HStack(spacing: Spacing.sm_) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                      .font(.system(size: TypeScale.caption, weight: .medium))
                    Text(copied ? "Copied!" : "Copy Hook Config")
                      .font(.system(size: TypeScale.caption, weight: .medium))
                  }
                  .foregroundStyle(copied ? Color.feedbackPositive : .primary)
                  .padding(.horizontal, Spacing.lg_)
                  .padding(.vertical, Spacing.sm)
                  .background(Color.accent.opacity(copied ? 0.2 : 1), in: RoundedRectangle(cornerRadius: Radius.md))
                  .foregroundStyle(copied ? Color.feedbackPositive : Color.backgroundPrimary)
                }
                .buttonStyle(.plain)

                Button {
                  openSettingsFile()
                } label: {
                  HStack(spacing: Spacing.sm_) {
                    Image(systemName: "arrow.up.forward.square")
                      .font(.system(size: TypeScale.meta, weight: .medium))
                    Text("Open File")
                      .font(.system(size: TypeScale.caption, weight: .medium))
                  }
                  .foregroundStyle(Color.accent)
                  .padding(.horizontal, Spacing.md)
                  .padding(.vertical, Spacing.sm)
                  .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: Radius.md))
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                  checkHooksConfiguration()
                } label: {
                  Image(systemName: "arrow.clockwise")
                    .font(.system(size: TypeScale.meta, weight: .medium))
                    .foregroundStyle(Color.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Check configuration")
              }
            }
          }
        }

        SettingsSection(title: "CODEX CLI", icon: "sparkles") {
          VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.sm) {
              Image(systemName: serverState
                .codexAccountStatus?.account == nil ? "person.crop.circle.badge.exclamationmark" :
                "person.crop.circle.badge.checkmark")
                .font(.system(size: TypeScale.body, weight: .semibold))
                .foregroundStyle(serverState.codexAccountStatus?.account == nil ? Color.statusPermission : Color.feedbackPositive)
              Text("Account")
                .font(.system(size: TypeScale.body, weight: .semibold))
              Spacer()
              codexAuthBadge
            }

            switch serverState.codexAccountStatus?.account {
              case .apiKey?:
                Text("Connected with API key. Switch to ChatGPT sign-in for subscription-backed limits.")
                  .font(.system(size: TypeScale.caption))
                  .foregroundStyle(Color.textSecondary)
              case let .chatgpt(email, planType)?:
                VStack(alignment: .leading, spacing: Spacing.xs) {
                  if let email {
                    Text(email)
                      .font(.system(size: TypeScale.body, weight: .medium))
                      .foregroundStyle(.primary)
                  } else {
                    Text("Signed in with ChatGPT")
                      .font(.system(size: TypeScale.body, weight: .medium))
                      .foregroundStyle(.primary)
                  }
                  if let planType {
                    Text(planType.uppercased())
                      .font(.system(size: TypeScale.meta, weight: .semibold, design: .rounded))
                      .foregroundStyle(Color.accent)
                  }
                }
              case .none:
                Text("Sign in with ChatGPT to manage Codex sessions directly in OrbitDock.")
                  .font(.system(size: TypeScale.caption))
                  .foregroundStyle(Color.textSecondary)
            }

            HStack(spacing: Spacing.md_) {
              if (serverState.codexAccountStatus?.loginInProgress == true) {
                Button {
                  serverState.cancelCodexChatgptLogin()
                } label: {
                  Label("Cancel Sign-In", systemImage: "xmark.circle")
                    .font(.system(size: TypeScale.caption, weight: .semibold))
                }
                .buttonStyle(.bordered)
              } else if serverState.codexAccountStatus?.account == nil {
                Button {
                  serverState.startCodexChatgptLogin()
                } label: {
                  Label("Sign in with ChatGPT", systemImage: "sparkles")
                    .font(.system(size: TypeScale.caption, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accent)
              }

              if serverState.codexAccountStatus?.account != nil {
                Button("Usage") {
                  openCodexUsagePage()
                }
                .font(.system(size: TypeScale.caption, weight: .semibold))
                .buttonStyle(.bordered)

                Button("Sign Out") {
                  serverState.logoutCodexAccount()
                }
                .font(.system(size: TypeScale.caption, weight: .semibold))
                .buttonStyle(.bordered)
              }

              Spacer()
            }

            if let error = serverState.codexAuthError, !error.isEmpty {
              HStack(spacing: Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                  .font(.system(size: TypeScale.meta))
                  .foregroundStyle(Color.statusPermission)
                Text(error)
                  .font(.system(size: TypeScale.meta))
                  .foregroundStyle(Color.textSecondary)
              }
            }
          }
        }
      }
      .padding(Spacing.xl)
    }
    .onAppear {
      checkHooksConfiguration()
      serverState.refreshCodexAccount()
    }
  }

  @ViewBuilder
  private var codexAuthBadge: some View {
    if (serverState.codexAccountStatus?.loginInProgress == true) {
      Label("Signing In", systemImage: "clock")
        .font(.system(size: TypeScale.micro, weight: .bold, design: .rounded))
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(Color.statusWorking.opacity(0.18), in: Capsule())
        .foregroundStyle(Color.statusWorking)
    } else if serverState.codexAccountStatus?.account == nil {
      Label("Not Connected", systemImage: "xmark")
        .font(.system(size: TypeScale.micro, weight: .bold, design: .rounded))
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(Color.statusPermission.opacity(0.16), in: Capsule())
        .foregroundStyle(Color.statusPermission)
    } else {
      Label("Connected", systemImage: "checkmark")
        .font(.system(size: TypeScale.micro, weight: .bold, design: .rounded))
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(Color.feedbackPositive.opacity(0.2), in: Capsule())
        .foregroundStyle(Color.feedbackPositive)
    }
  }

  private func checkHooksConfiguration() {
    hooksConfigured = nil
    DispatchQueue.global(qos: .userInitiated).async {
      let configured = isHooksConfigured()
      DispatchQueue.main.async {
        hooksConfigured = configured
      }
    }
  }

  private func isHooksConfigured() -> Bool {
    guard FileManager.default.fileExists(atPath: settingsPath),
          let data = FileManager.default.contents(atPath: settingsPath),
          let content = String(data: data, encoding: .utf8)
    else {
      return false
    }
    return content.contains("orbitdock") || content.contains("hook-forward")
  }

  private func copyToClipboard() {
    Platform.services.copyToClipboard(hooksConfigJSON)
    copied = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
      copied = false
    }
  }

  private func openSettingsFile() {
    if !FileManager.default.fileExists(atPath: settingsPath) {
      let dir = (settingsPath as NSString).deletingLastPathComponent
      try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
      try? "{}".write(toFile: settingsPath, atomically: true, encoding: .utf8)
    }
    _ = Platform.services.openURL(URL(fileURLWithPath: settingsPath))
  }

  private func openCodexUsagePage() {
    guard let url = URL(string: "https://chatgpt.com/codex/settings/usage") else { return }
    _ = Platform.services.openURL(url)
  }

  private var hooksConfigJSON: String {
    """
      "hooks": {
      "SessionStart": [{"hooks": [{"type": "command", "command": "\"\(
        hookForwardPath
      )\" hook-forward claude_session_start", "async": true}]}],
      "SessionEnd": [{"hooks": [{"type": "command", "command": "\"\(
        hookForwardPath
      )\" hook-forward claude_session_end", "async": true}]}],
      "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "\"\(
        hookForwardPath
      )\" hook-forward claude_status_event", "async": true}]}],
      "Stop": [{"hooks": [{"type": "command", "command": "\"\(
        hookForwardPath
      )\" hook-forward claude_status_event", "async": true}]}],
      "Notification": [{"matcher": "idle_prompt|permission_prompt|elicitation_dialog", "hooks": [{"type": "command", "command": "\"\(
        hookForwardPath
      )\" hook-forward claude_status_event", "async": true}]}],
      "PreCompact": [{"hooks": [{"type": "command", "command": "\"\(
        hookForwardPath
      )\" hook-forward claude_status_event", "async": true}]}],
      "TeammateIdle": [{"hooks": [{"type": "command", "command": "\"\(
        hookForwardPath
      )\" hook-forward claude_status_event", "async": true}]}],
      "TaskCompleted": [{"hooks": [{"type": "command", "command": "\"\(
        hookForwardPath
      )\" hook-forward claude_status_event", "async": true}]}],
      "ConfigChange": [{"hooks": [{"type": "command", "command": "\"\(
        hookForwardPath
      )\" hook-forward claude_status_event", "async": true}]}],
      "PreToolUse": [{"hooks": [{"type": "command", "command": "\"\(
        hookForwardPath
      )\" hook-forward claude_tool_event", "async": true}]}],
      "PostToolUse": [{"hooks": [{"type": "command", "command": "\"\(
        hookForwardPath
      )\" hook-forward claude_tool_event", "async": true}]}],
      "PostToolUseFailure": [{"hooks": [{"type": "command", "command": "\"\(
        hookForwardPath
      )\" hook-forward claude_tool_event", "async": true}]}],
      "PermissionRequest": [{"hooks": [{"type": "command", "command": "\"\(
        hookForwardPath
      )\" hook-forward claude_tool_event", "async": true}]}],
      "SubagentStart": [{"hooks": [{"type": "command", "command": "\"\(
        hookForwardPath
      )\" hook-forward claude_subagent_event", "async": true}]}],
      "SubagentStop": [{"hooks": [{"type": "command", "command": "\"\(
        hookForwardPath
      )\" hook-forward claude_subagent_event", "async": true}]}]
    }
    """
  }
}
