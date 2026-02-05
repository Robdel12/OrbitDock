//
//  SettingsView.swift
//  OrbitDock
//
//  Settings/Preferences window - Cosmic Harbor theme
//

import SwiftUI
import UserNotifications

struct SettingsView: View {
  @State private var selectedTab = 0

  var body: some View {
    VStack(spacing: 0) {
      // Tab bar
      HStack(spacing: 2) {
        SettingsTabButton(
          title: "General",
          icon: "gear",
          isSelected: selectedTab == 0
        ) { selectedTab = 0 }

        SettingsTabButton(
          title: "Notifications",
          icon: "bell.badge",
          isSelected: selectedTab == 1
        ) { selectedTab = 1 }

        SettingsTabButton(
          title: "Setup",
          icon: "wrench.and.screwdriver",
          isSelected: selectedTab == 2
        ) { selectedTab = 2 }

        SettingsTabButton(
          title: "Debug",
          icon: "ladybug",
          isSelected: selectedTab == 3
        ) { selectedTab = 3 }
      }
      .padding(.horizontal, 16)
      .padding(.top, 16)
      .padding(.bottom, 12)

      Divider()
        .foregroundStyle(Color.panelBorder)

      // Content
      Group {
        switch selectedTab {
        case 0:
          GeneralSettingsView()
        case 1:
          NotificationSettingsView()
        case 2:
          SetupSettingsView()
        case 3:
          DebugSettingsView()
        default:
          GeneralSettingsView()
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(width: 520, height: 480)
    .background(Color.backgroundPrimary)
  }
}

// MARK: - Tab Button

struct SettingsTabButton: View {
  let title: String
  let icon: String
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: icon)
          .font(.system(size: 12, weight: .medium))
        Text(title)
          .font(.system(size: 13, weight: .medium))
      }
      .foregroundStyle(isSelected ? Color.accent : .secondary)
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(isSelected ? Color.surfaceSelected : Color.clear)
      )
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Settings Section

struct SettingsSection<Content: View>: View {
  let title: String
  let icon: String
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      // Header
      HStack(spacing: 6) {
        Image(systemName: icon)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Color.accent)
        Text(title)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.secondary)
      }

      // Content card
      VStack(alignment: .leading, spacing: 12) {
        content()
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.backgroundSecondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .strokeBorder(Color.panelBorder, lineWidth: 1)
      )
    }
  }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
  @AppStorage("preferredEditor") private var preferredEditor: String = ""

  private let editors: [(id: String, name: String, icon: String)] = [
    ("", "System Default (Finder)", "folder"),
    ("code", "Visual Studio Code", "chevron.left.forwardslash.chevron.right"),
    ("cursor", "Cursor", "cursorarrow"),
    ("zed", "Zed", "bolt.fill"),
    ("subl", "Sublime Text", "text.alignleft"),
    ("emacs", "Emacs", "terminal"),
    ("vim", "Vim", "terminal.fill"),
    ("nvim", "Neovim", "terminal.fill"),
  ]

  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        SettingsSection(title: "EDITOR", icon: "chevron.left.forwardslash.chevron.right") {
          VStack(alignment: .leading, spacing: 10) {
            HStack {
              Text("Default Editor")
                .font(.system(size: 13))

              Spacer()

              Picker("", selection: $preferredEditor) {
                ForEach(editors, id: \.id) { editor in
                  Text(editor.name).tag(editor.id)
                }
              }
              .pickerStyle(.menu)
              .frame(width: 200)
              .tint(Color.accent)
            }

            Text("Used when clicking project paths to open in your editor.")
              .font(.system(size: 11))
              .foregroundStyle(.tertiary)
          }
        }
      }
      .padding(20)
    }
  }
}

// MARK: - Notification Settings

struct NotificationSettingsView: View {
  @AppStorage("notificationsEnabled") private var notificationsEnabled = true
  @AppStorage("notifyOnWorkComplete") private var notifyOnWorkComplete = true
  @AppStorage("notificationSound") private var notificationSound = "default"

  private let systemSounds: [(id: String, name: String)] = [
    ("default", "Default"),
    ("Basso", "Basso"),
    ("Blow", "Blow"),
    ("Bottle", "Bottle"),
    ("Frog", "Frog"),
    ("Funk", "Funk"),
    ("Glass", "Glass"),
    ("Hero", "Hero"),
    ("Morse", "Morse"),
    ("Ping", "Ping"),
    ("Pop", "Pop"),
    ("Purr", "Purr"),
    ("Sosumi", "Sosumi"),
    ("Submarine", "Submarine"),
    ("Tink", "Tink"),
    ("none", "None"),
  ]

  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        SettingsSection(title: "ALERTS", icon: "bell.badge") {
          VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
              Toggle(isOn: $notificationsEnabled) {
                Text("Enable Notifications")
                  .font(.system(size: 13))
              }
              .toggleStyle(.switch)
              .tint(Color.accent)

              Text("Master switch for all OrbitDock notifications.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            }

            Divider()
              .foregroundStyle(Color.panelBorder)

            VStack(alignment: .leading, spacing: 6) {
              Toggle(isOn: $notifyOnWorkComplete) {
                Text("Notify When Agent Finishes")
                  .font(.system(size: 13))
              }
              .toggleStyle(.switch)
              .tint(Color.accent)
              .disabled(!notificationsEnabled)

              Text("Alert when a session stops working and is ready for input.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            }
            .opacity(notificationsEnabled ? 1 : 0.5)
          }
        }

        SettingsSection(title: "SOUND", icon: "speaker.wave.2") {
          VStack(alignment: .leading, spacing: 10) {
            HStack {
              Text("Notification Sound")
                .font(.system(size: 13))

              Spacer()

              Picker("", selection: $notificationSound) {
                ForEach(systemSounds, id: \.id) { sound in
                  Text(sound.name).tag(sound.id)
                }
              }
              .pickerStyle(.menu)
              .frame(width: 140)
              .tint(Color.accent)

              Button {
                previewSound()
              } label: {
                Image(systemName: "play.fill")
                  .font(.system(size: 10, weight: .semibold))
                  .foregroundStyle(notificationSound == "none" ? Color.textTertiary : Color.accent)
                  .frame(width: 28, height: 28)
                  .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                  .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                      .strokeBorder(Color.panelBorder, lineWidth: 1)
                  )
              }
              .buttonStyle(.plain)
              .disabled(notificationSound == "none")
              .help("Preview sound")
            }

            Text("Plays when a session needs your attention.")
              .font(.system(size: 11))
              .foregroundStyle(.tertiary)
          }
        }
        .opacity(notificationsEnabled ? 1 : 0.5)
        .allowsHitTesting(notificationsEnabled)

        // Test notification button
        Button {
          sendTestNotification()
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "bell.badge")
              .font(.system(size: 11, weight: .medium))
            Text("Send Test Notification")
              .font(.system(size: 12, weight: .medium))
          }
          .foregroundStyle(notificationsEnabled ? Color.accent : Color.textTertiary)
          .padding(.horizontal, 14)
          .padding(.vertical, 8)
          .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .strokeBorder(Color.panelBorder, lineWidth: 1)
          )
        }
        .buttonStyle(.plain)
        .disabled(!notificationsEnabled)
        .help("Send a test notification to verify your settings")
      }
      .padding(20)
    }
  }

  private func previewSound() {
    guard notificationSound != "none" else { return }

    if notificationSound == "default" {
      NSSound.beep()
    } else if let sound = NSSound(named: NSSound.Name(notificationSound)) {
      sound.play()
    }
  }

  private func sendTestNotification() {
    let content = UNMutableNotificationContent()
    content.title = "Test Notification"
    content.subtitle = "OrbitDock"
    content.body = "This is a test notification. Your settings are working!"
    content.categoryIdentifier = "SESSION_ATTENTION"

    // Apply the configured sound
    switch notificationSound {
      case "none":
        content.sound = nil
      case "default":
        content.sound = .default
      default:
        content.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: notificationSound))
    }

    let request = UNNotificationRequest(
      identifier: "test-notification-\(UUID().uuidString)",
      content: content,
      trigger: nil
    )

    UNUserNotificationCenter.current().add(request)
  }
}

// MARK: - Setup Settings

struct SetupSettingsView: View {
  @State private var copied = false
  @State private var hooksConfigured: Bool? = nil

  private let cliPath = "/Applications/OrbitDock.app/Contents/MacOS/orbitdock-cli"
  private let settingsPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude/settings.json").path

  var body: some View {
    VStack(spacing: 20) {
      // Claude Code section
      SettingsSection(title: "CLAUDE CODE", icon: "terminal") {
        VStack(alignment: .leading, spacing: 14) {
          // Status row
          HStack {
            if let configured = hooksConfigured {
              if configured {
                Image(systemName: "checkmark.circle.fill")
                  .foregroundStyle(Color.statusSuccess)
                Text("Hooks configured")
                  .font(.system(size: 13))
              } else {
                Image(systemName: "exclamationmark.circle.fill")
                  .foregroundStyle(Color.statusPermission)
                Text("Hooks not configured")
                  .font(.system(size: 13))
              }
            } else {
              ProgressView()
                .controlSize(.small)
              Text("Checking...")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            }
            Spacer()
          }

          Divider()
            .foregroundStyle(Color.panelBorder)

          // Instructions
          VStack(alignment: .leading, spacing: 8) {
            Text("Add hooks to ~/.claude/settings.json:")
              .font(.system(size: 12))
              .foregroundStyle(.secondary)

            HStack(spacing: 10) {
              Button {
                copyToClipboard()
              } label: {
                HStack(spacing: 6) {
                  Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .medium))
                  Text(copied ? "Copied!" : "Copy Hook Config")
                    .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(copied ? Color.statusSuccess : .primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.accent.opacity(copied ? 0.2 : 1), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(copied ? Color.statusSuccess : Color.backgroundPrimary)
              }
              .buttonStyle(.plain)

              Button {
                openSettingsFile()
              } label: {
                HStack(spacing: 6) {
                  Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 11, weight: .medium))
                  Text("Open File")
                    .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Color.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: 6))
              }
              .buttonStyle(.plain)

              Spacer()

              Button {
                checkHooksConfiguration()
              } label: {
                Image(systemName: "arrow.clockwise")
                  .font(.system(size: 11, weight: .medium))
                  .foregroundStyle(.secondary)
              }
              .buttonStyle(.plain)
              .help("Check configuration")
            }
          }
        }
      }

      // Codex section
      SettingsSection(title: "CODEX CLI", icon: "sparkles") {
        HStack {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(Color.statusSuccess)
          Text("Automatic via FSEvents — no setup needed")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
          Spacer()
        }
      }

      Spacer()
    }
    .padding(20)
    .onAppear {
      checkHooksConfiguration()
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
          let content = String(data: data, encoding: .utf8) else {
      return false
    }
    return content.contains("orbitdock-cli")
  }

  private func copyToClipboard() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(hooksConfigJSON, forType: .string)
    copied = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
      copied = false
    }
  }

  private func openSettingsFile() {
    // Create file if it doesn't exist
    if !FileManager.default.fileExists(atPath: settingsPath) {
      let dir = (settingsPath as NSString).deletingLastPathComponent
      try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
      try? "{}".write(toFile: settingsPath, atomically: true, encoding: .utf8)
    }
    NSWorkspace.shared.open(URL(fileURLWithPath: settingsPath))
  }

  private var hooksConfigJSON: String {
    """
    "hooks": {
      "SessionStart": [{"hooks": [{"type": "command", "command": "\(cliPath) session-start", "async": true}]}],
      "SessionEnd": [{"hooks": [{"type": "command", "command": "\(cliPath) session-end", "async": true}]}],
      "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "\(cliPath) status-tracker", "async": true}]}],
      "Stop": [{"hooks": [{"type": "command", "command": "\(cliPath) status-tracker", "async": true}]}],
      "Notification": {"matcher": "idle_prompt|permission_prompt", "hooks": [{"type": "command", "command": "\(cliPath) status-tracker", "async": true}]},
      "PreToolUse": [{"hooks": [{"type": "command", "command": "\(cliPath) tool-tracker", "async": true}]}],
      "PostToolUse": [{"hooks": [{"type": "command", "command": "\(cliPath) tool-tracker", "async": true}]}],
      "PostToolUseFailure": [{"hooks": [{"type": "command", "command": "\(cliPath) tool-tracker", "async": true}]}]
    }
    """
  }
}

// MARK: - Debug Settings

struct DebugSettingsView: View {
  @StateObject private var serverManager = ServerManager.shared
  @StateObject private var serverConnection = ServerConnection.shared
  @State private var showServerTest = false

  var body: some View {
    VStack(spacing: 20) {
      SettingsSection(title: "RUST SERVER", icon: "server.rack") {
        VStack(alignment: .leading, spacing: 14) {
          // Server process status
          HStack {
            Circle()
              .fill(serverManager.isRunning ? Color.statusSuccess : Color.statusEnded)
              .frame(width: 8, height: 8)

            Text(serverManager.isRunning ? "Server Running" : "Server Stopped")
              .font(.system(size: 13))

            Spacer()

            if serverManager.isRunning {
              Button("Stop") {
                serverManager.stop()
              }
              .buttonStyle(.bordered)
            } else {
              Button("Start") {
                serverManager.start()
              }
              .buttonStyle(.borderedProminent)
              .tint(Color.accent)
            }
          }

          if let error = serverManager.lastError {
            Text(error)
              .font(.system(size: 11))
              .foregroundStyle(.red)
          }

          Divider()
            .foregroundStyle(Color.panelBorder)

          // WebSocket status
          HStack {
            Circle()
              .fill(connectionColor)
              .frame(width: 8, height: 8)

            Text("WebSocket: \(connectionText)")
              .font(.system(size: 13))

            Spacer()

            Button("Test View") {
              showServerTest = true
            }
            .buttonStyle(.bordered)
          }
        }
      }

      SettingsSection(title: "LOGS", icon: "doc.text") {
        VStack(alignment: .leading, spacing: 14) {
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text("Codex Logs")
                .font(.system(size: 13))
              Text("~/.orbitdock/logs/codex.log")
                .font(.system(size: 11).monospaced())
                .foregroundStyle(.tertiary)
            }

            Spacer()

            Button("Open in Finder") {
              let path = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".orbitdock/logs")
              NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path.path)
            }
            .buttonStyle(.bordered)
          }
        }
      }

      SettingsSection(title: "DATABASE", icon: "cylinder") {
        VStack(alignment: .leading, spacing: 14) {
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text("OrbitDock Database")
                .font(.system(size: 13))
              Text("~/.orbitdock/orbitdock.db")
                .font(.system(size: 11).monospaced())
                .foregroundStyle(.tertiary)
            }

            Spacer()

            Button("Open in Finder") {
              let path = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".orbitdock")
              NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path.path)
            }
            .buttonStyle(.bordered)
          }
        }
      }

      Spacer()
    }
    .padding(20)
    .sheet(isPresented: $showServerTest) {
      ServerTestView()
    }
  }

  private var connectionColor: Color {
    switch serverConnection.status {
    case .connected:
      return .statusSuccess
    case .connecting, .reconnecting:
      return .yellow
    case .disconnected:
      return .statusEnded
    }
  }

  private var connectionText: String {
    switch serverConnection.status {
    case .connected:
      return "Connected"
    case .connecting:
      return "Connecting..."
    case .reconnecting(let attempt):
      return "Reconnecting (\(attempt))..."
    case .disconnected:
      return "Disconnected"
    }
  }
}

// MARK: - Preview

#Preview {
  SettingsView()
    .preferredColorScheme(.dark)
}
