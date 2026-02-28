//
//  SettingsView.swift
//  OrbitDock
//
//  Settings/Preferences window - Cosmic Harbor theme
//

import SwiftUI
import UserNotifications

private enum SettingsPane: String, CaseIterable, Identifiable {
  case workspace
  case integrations
  case servers
  case notifications
  case diagnostics

  var id: String {
    rawValue
  }

  var title: String {
    switch self {
      case .workspace:
        "Workspace"
      case .integrations:
        "Integrations"
      case .servers:
        "Servers"
      case .notifications:
        "Notifications"
      case .diagnostics:
        "Diagnostics"
    }
  }

  var subtitle: String {
    switch self {
      case .workspace:
        "Editor, naming, and local dictation"
      case .integrations:
        "Claude hooks and Codex account"
      case .servers:
        "Endpoints, runtime, and connection"
      case .notifications:
        "Alerts, sounds, and previews"
      case .diagnostics:
        "Logs, database, and support paths"
    }
  }

  var icon: String {
    switch self {
      case .workspace:
        "slider.horizontal.3"
      case .integrations:
        "puzzlepiece.extension"
      case .servers:
        "server.rack"
      case .notifications:
        "bell.badge"
      case .diagnostics:
        "stethoscope"
    }
  }
}

struct SettingsView: View {
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry
  @Environment(\.dismiss) private var dismiss
  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  #endif

  private let showsCloseButton: Bool
  @State private var selectedPane: SettingsPane = .workspace

  init(showsCloseButton: Bool = false) {
    self.showsCloseButton = showsCloseButton
  }

  private var enabledEndpointCount: Int {
    runtimeRegistry.runtimes.filter(\.endpoint.isEnabled).count
  }

  private var connectedEndpointCount: Int {
    runtimeRegistry.runtimes.filter { runtime in
      let status = runtimeRegistry.connectionStatusByEndpointId[runtime.endpoint.id] ?? runtime.connection.status
      if case .connected = status {
        return true
      }
      return false
    }.count
  }

  private var endpointHealthColor: Color {
    if enabledEndpointCount > 0, connectedEndpointCount == enabledEndpointCount {
      return Color.statusSuccess
    }
    if connectedEndpointCount > 0 {
      return Color.statusQuestion
    }
    return Color.statusPermission
  }

  private var endpointHealthText: String {
    if enabledEndpointCount == 0 {
      return "No enabled endpoints"
    }
    return "\(connectedEndpointCount)/\(enabledEndpointCount) connected"
  }

  private var usesCompactLayout: Bool {
    #if os(iOS)
      horizontalSizeClass == .compact
    #else
      false
    #endif
  }

  var body: some View {
    Group {
      if usesCompactLayout {
        compactLayout
      } else {
        splitLayout
      }
    }
    #if os(macOS)
    .frame(width: 900, height: 620)
    #else
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    #endif
    .background(
      ZStack {
        Color.backgroundPrimary
        LinearGradient(
          colors: [
            Color.accent.opacity(0.10),
            Color.clear,
            Color.statusQuestion.opacity(0.08),
          ],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      }
    )
    .animation(.spring(response: 0.24, dampingFraction: 0.86), value: selectedPane)
  }

  private var splitLayout: some View {
    HStack(spacing: 0) {
      sidebar
      Divider()
        .foregroundStyle(Color.panelBorder)
      detailPane
    }
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: Spacing.xs) {
        Text("OrbitDock")
          .font(.system(size: 12, weight: .semibold, design: .rounded))
          .foregroundStyle(Color.accent)
        Text("Preferences")
          .font(.system(size: 22, weight: .bold, design: .rounded))
          .foregroundStyle(Color.textPrimary)
      }

      VStack(spacing: Spacing.sm) {
        ForEach(SettingsPane.allCases) { pane in
          SettingsSidebarButton(
            title: pane.title,
            subtitle: pane.subtitle,
            icon: pane.icon,
            isSelected: selectedPane == pane
          ) {
            selectedPane = pane
          }
        }
      }

      Spacer()

      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          Circle()
            .fill(endpointHealthColor)
            .frame(width: 7, height: 7)
          Text("Endpoint Health")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.textSecondary)
        }

        Text(endpointHealthText)
          .font(.system(size: 10, weight: .semibold, design: .monospaced))
          .foregroundStyle(Color.textTertiary)
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        Color.backgroundTertiary.opacity(OpacityTier.vivid),
        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .strokeBorder(Color.panelBorder, lineWidth: 1)
      )
    }
    .padding(Spacing.section)
    .frame(width: 260)
    .frame(maxHeight: .infinity, alignment: .topLeading)
    .background(Color.backgroundSecondary.opacity(0.8))
  }

  private var compactLayout: some View {
    VStack(spacing: 0) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text("Preferences")
          .font(.system(size: 20, weight: .bold, design: .rounded))
          .foregroundStyle(Color.textPrimary)
        Spacer()
        #if os(iOS)
          if showsCloseButton {
            Button("Done") {
              dismiss()
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.accent)
          }
        #endif
      }
      .padding(.horizontal, Spacing.section)
      .padding(.top, 16)
      .padding(.bottom, 12)

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(SettingsPane.allCases) { pane in
            Button {
              selectedPane = pane
            } label: {
              HStack(spacing: 6) {
                Image(systemName: pane.icon)
                  .font(.system(size: 10, weight: .semibold))
                Text(pane.title)
                  .font(.system(size: 11, weight: .semibold))
              }
              .foregroundStyle(selectedPane == pane ? Color.accent : Color.textSecondary)
              .padding(.horizontal, Spacing.md)
              .padding(.vertical, Spacing.sm)
              .background(
                Capsule(style: .continuous)
                  .fill(selectedPane == pane ? Color.surfaceSelected : Color.backgroundTertiary.opacity(0.8))
              )
              .overlay(
                Capsule(style: .continuous)
                  .strokeBorder(selectedPane == pane ? Color.surfaceBorder : Color.clear, lineWidth: 1)
              )
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, Spacing.section)
      }
      .padding(.bottom, 12)

      Divider()
        .foregroundStyle(Color.panelBorder)

      Group {
        switch selectedPane {
          case .workspace:
            GeneralSettingsView()
          case .integrations:
            SetupSettingsView()
          case .servers:
            DebugSettingsView()
          case .notifications:
            NotificationSettingsView()
          case .diagnostics:
            DiagnosticsSettingsView()
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var detailPane: some View {
    VStack(spacing: 0) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text(selectedPane.title)
          .font(.system(size: 20, weight: .bold, design: .rounded))
          .foregroundStyle(Color.textPrimary)
        Text(selectedPane.subtitle)
          .font(.system(size: 12))
          .foregroundStyle(Color.textTertiary)
          .lineLimit(1)
        Spacer()
        #if os(iOS)
          if showsCloseButton {
            Button("Done") {
              dismiss()
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.accent)
          }
        #endif
      }
      .padding(.horizontal, Spacing.xl)
      .padding(.top, Spacing.section)
      .padding(.bottom, Spacing.lg)

      Divider()
        .foregroundStyle(Color.panelBorder)

      Group {
        switch selectedPane {
          case .workspace:
            GeneralSettingsView()
          case .integrations:
            SetupSettingsView()
          case .servers:
            DebugSettingsView()
          case .notifications:
            NotificationSettingsView()
          case .diagnostics:
            DiagnosticsSettingsView()
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

// MARK: - Sidebar Button

struct SettingsSidebarButton: View {
  let title: String
  let subtitle: String
  let icon: String
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: icon)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(isSelected ? Color.accent : Color.textTertiary)
          .frame(width: 18)

        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isSelected ? Color.textPrimary : Color.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
          Text(subtitle)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color.textQuaternary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .background(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(isSelected ? Color.surfaceSelected : Color.clear)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .strokeBorder(isSelected ? Color.surfaceBorder : Color.clear, lineWidth: 1)
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
    VStack(alignment: .leading, spacing: Spacing.md) {
      // Header
      HStack(spacing: 6) {
        Image(systemName: icon)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Color.accent)
        Text(title)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(Color.textSecondary)
      }

      // Content card
      VStack(alignment: .leading, spacing: Spacing.lg) {
        content()
      }
      .padding(Spacing.lg + 4)
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
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry
  @AppStorage("preferredEditor") private var preferredEditor: String = ""
  @AppStorage("whisperDictationEnabled") private var whisperDictationEnabled = true
  @State private var openAiKey: String = ""
  @State private var openAiKeySaved = false
  @State private var openAiKeyStatus: OpenAiKeyStatus = .checking
  @State private var isReplacingKey = false
  @State private var openAiKeyStatusRequestId = UUID()

  private enum OpenAiKeyStatus {
    case checking, configured, notConfigured
  }

  private enum WhisperModelStatus {
    case unavailable(message: String)
    case missing
    case ready
  }

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
      VStack(spacing: Spacing.xl) {
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
              .foregroundStyle(Color.textTertiary)
          }
        }

        SettingsSection(title: "AI NAMING", icon: "sparkles") {
          VStack(alignment: .leading, spacing: 12) {
            // Status row
            HStack {
              switch openAiKeyStatus {
                case .checking:
                  ProgressView()
                    .controlSize(.small)
                  Text("Checking...")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.textSecondary)
                case .configured:
                  Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.statusSuccess)
                  Text("API key configured")
                    .font(.system(size: 13))
                  Spacer()
                  Image(systemName: "lock.shield.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textTertiary)
                  Text("Encrypted")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.textTertiary)
                case .notConfigured:
                  Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(Color.statusPermission)
                  Text("No API key set")
                    .font(.system(size: 13))
              }
              Spacer()
            }

            Divider()
              .foregroundStyle(Color.panelBorder)

            VStack(alignment: .leading, spacing: 8) {
              if openAiKeyStatus == .configured, !isReplacingKey {
                // Key exists — show confirmation with option to replace
                Text("OpenAI API key for auto-naming sessions from first prompts.")
                  .font(.system(size: 12))
                  .foregroundStyle(Color.textSecondary)

                HStack(spacing: 8) {
                  HStack(spacing: 6) {
                    Image(systemName: "key.fill")
                      .font(.system(size: 10))
                      .foregroundStyle(Color.textTertiary)
                    Text("sk-\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}")
                      .font(.system(size: 12).monospaced())
                      .foregroundStyle(Color.textSecondary)
                  }
                  .padding(.horizontal, 10)
                  .padding(.vertical, 7)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                  .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                      .strokeBorder(Color.panelBorder, lineWidth: 1)
                  )

                  Button {
                    isReplacingKey = true
                  } label: {
                    Text("Replace")
                      .font(.system(size: 12, weight: .medium))
                      .foregroundStyle(Color.accent)
                      .padding(.horizontal, 12)
                      .padding(.vertical, 7)
                      .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: 6))
                  }
                  .buttonStyle(.plain)
                }
              } else {
                // No key yet, or replacing — show input field
                Text(isReplacingKey
                  ? "Enter a new key to replace the existing one."
                  : "OpenAI API key for auto-naming sessions from first prompts.")
                  .font(.system(size: 12))
                  .foregroundStyle(Color.textSecondary)

                HStack(spacing: 8) {
                  SecureField("sk-...", text: $openAiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12).monospaced())

                  Button {
                    saveOpenAiKey()
                  } label: {
                    HStack(spacing: 4) {
                      Image(systemName: openAiKeySaved ? "checkmark" : "arrow.up.circle")
                        .font(.system(size: 11, weight: .medium))
                      Text(openAiKeySaved ? "Saved" : "Save")
                        .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(openAiKeySaved ? Color.statusSuccess : Color.backgroundPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                      openAiKeySaved ? Color.statusSuccess.opacity(0.2) : Color.accent,
                      in: RoundedRectangle(cornerRadius: 6)
                    )
                  }
                  .buttonStyle(.plain)
                  .disabled(openAiKey.isEmpty)

                  if isReplacingKey {
                    Button {
                      isReplacingKey = false
                      openAiKey = ""
                    } label: {
                      Text("Cancel")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                    }
                    .buttonStyle(.plain)
                  }
                }

                if openAiKeySaved {
                  Text("Key encrypted and saved — new sessions will be auto-named.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textTertiary)
                }
              }
            }
          }
        }

        SettingsSection(title: "WHISPER DICTATION", icon: "waveform.badge.mic") {
          VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
              Toggle(isOn: $whisperDictationEnabled) {
                Text("Enable Local Dictation")
                  .font(.system(size: 13))
              }
              .toggleStyle(.switch)
              .tint(Color.accent)

              Text("Transcribe microphone audio on-device using whisper.cpp.")
                .font(.system(size: 11))
                .foregroundStyle(Color.textTertiary)
            }

            Divider()
              .foregroundStyle(Color.panelBorder)

            HStack(spacing: 8) {
              switch whisperModelStatus {
                case .ready:
                  Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.statusSuccess)
                  Text("Model ready")
                    .font(.system(size: 13))
                case .missing:
                  Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(Color.statusPermission)
                  Text("Model not found")
                    .font(.system(size: 13))
                case .unavailable:
                  Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Color.statusError)
                  Text("Whisper unavailable in this build")
                    .font(.system(size: 13))
              }
              Spacer()
            }

            switch whisperModelStatus {
              case .missing:
                Text(
                  """
                  OrbitDock checks for a bundled \(WhisperModelLocator.defaultModelFileName) first, \
                  then falls back to Application Support.
                  """
                )
                .font(.system(size: 11))
                .foregroundStyle(Color.textTertiary)
              case let .unavailable(message):
                Text(message)
                  .font(.system(size: 11))
                  .foregroundStyle(Color.textTertiary)
              case .ready:
                Text("Local Whisper model is available and ready for dictation.")
                  .font(.system(size: 11))
                  .foregroundStyle(Color.textTertiary)
            }
          }
        }
      }
      .padding(Spacing.xl)
    }
    .onAppear {
      checkOpenAiKeyStatus()
    }
  }

  private var whisperModelStatus: WhisperModelStatus {
    #if canImport(whisper) || canImport(Whisper)
      let locator = WhisperModelLocator()
      if (try? locator.resolveModelPath()) != nil {
        return .ready
      }
      return .missing
    #else
      return .unavailable(message: "Whisper is not linked for this build target.")
    #endif
  }

  private func saveOpenAiKey() {
    guard let connection = runtimeRegistry.controlPlaneConnection else { return }
    connection.setOpenAiKey(openAiKey)
    openAiKeySaved = true
    openAiKey = ""
    isReplacingKey = false
    checkOpenAiKeyStatus()
  }

  private func checkOpenAiKeyStatus() {
    guard let connection = runtimeRegistry.controlPlaneConnection else {
      openAiKeyStatus = .notConfigured
      return
    }

    openAiKeyStatus = .checking
    let endpointId = connection.endpointId
    let requestId = UUID()
    openAiKeyStatusRequestId = requestId

    Task { @MainActor in
      do {
        let configured = try await connection.checkOpenAiKeyStatus()
        guard openAiKeyStatusRequestId == requestId,
              runtimeRegistry.controlPlaneConnection?.endpointId == endpointId
        else { return }
        openAiKeyStatus = configured ? .configured : .notConfigured
      } catch {
        guard openAiKeyStatusRequestId == requestId,
              runtimeRegistry.controlPlaneConnection?.endpointId == endpointId
        else { return }
        openAiKeyStatus = .notConfigured
      }
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
      VStack(spacing: Spacing.xl) {
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
                .foregroundStyle(Color.textTertiary)
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
                .foregroundStyle(Color.textTertiary)
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
              .foregroundStyle(Color.textTertiary)
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
      .padding(Spacing.xl)
    }
  }

  private func previewSound() {
    guard notificationSound != "none" else { return }
    guard Platform.services.capabilities.canPlaySystemSounds else { return }

    #if os(macOS)
      if notificationSound == "default" {
        NSSound.beep()
      } else if let sound = NSSound(named: NSSound.Name(notificationSound)) {
        sound.play()
      }
    #endif
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
  @Environment(ServerAppState.self) private var serverState
  @State private var copied = false
  @State private var hooksConfigured: Bool? = nil

  private let hookForwardPath = "/Applications/OrbitDock.app/Contents/Resources/orbitdock-server"
  private let settingsPath = PlatformPaths.homeDirectory
    .appendingPathComponent(".claude/settings.json").path

  var body: some View {
    ScrollView {
      VStack(spacing: Spacing.xl) {
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
                  .foregroundStyle(Color.textSecondary)
              }
              Spacer()
            }

            Divider()
              .foregroundStyle(Color.panelBorder)

            // Instructions
            VStack(alignment: .leading, spacing: 8) {
              Text("Add hooks to ~/.claude/settings.json:")
                .font(.system(size: 12))
                .foregroundStyle(Color.textSecondary)

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
                    .foregroundStyle(Color.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Check configuration")
              }
            }
          }
        }

        // Codex section
        SettingsSection(title: "CODEX CLI", icon: "sparkles") {
          VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
              Image(systemName: serverState
                .codexAccount == nil ? "person.crop.circle.badge.exclamationmark" :
                "person.crop.circle.badge.checkmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(serverState.codexAccount == nil ? Color.statusPermission : Color.statusSuccess)
              Text("Account")
                .font(.system(size: 13, weight: .semibold))
              Spacer()
              codexAuthBadge
            }

            switch serverState.codexAccount {
              case .apiKey?:
                Text("Connected with API key. Switch to ChatGPT sign-in for subscription-backed limits.")
                  .font(.system(size: 12))
                  .foregroundStyle(Color.textSecondary)
              case let .chatgpt(email, planType)?:
                VStack(alignment: .leading, spacing: 4) {
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
                Text("Sign in with ChatGPT to manage Codex sessions directly in OrbitDock.")
                  .font(.system(size: 12))
                  .foregroundStyle(Color.textSecondary)
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
              } else if serverState.codexAccount == nil {
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
                Button("Usage") {
                  openCodexUsagePage()
                }
                .font(.system(size: 12, weight: .semibold))
                .buttonStyle(.bordered)

                Button("Sign Out") {
                  serverState.logoutCodexAccount()
                }
                .font(.system(size: 12, weight: .semibold))
                .buttonStyle(.bordered)
              }

              Spacer()
            }

            if let error = serverState.codexAuthError, !error.isEmpty {
              HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                  .font(.system(size: 11))
                  .foregroundStyle(Color.statusPermission)
                Text(error)
                  .font(.system(size: 11))
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
    if serverState.codexLoginInProgress {
      Label("Signing In", systemImage: "clock")
        .font(.system(size: 10, weight: .bold, design: .rounded))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.statusWorking.opacity(0.18), in: Capsule())
        .foregroundStyle(Color.statusWorking)
    } else if serverState.codexAccount == nil {
      Label("Not Connected", systemImage: "xmark")
        .font(.system(size: 10, weight: .bold, design: .rounded))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.statusPermission.opacity(0.16), in: Capsule())
        .foregroundStyle(Color.statusPermission)
    } else {
      Label("Connected", systemImage: "checkmark")
        .font(.system(size: 10, weight: .bold, design: .rounded))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.statusSuccess.opacity(0.2), in: Capsule())
        .foregroundStyle(Color.statusSuccess)
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
    return content.contains("orbitdock-server") || content.contains("hook-forward")
  }

  private func copyToClipboard() {
    Platform.services.copyToClipboard(hooksConfigJSON)
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

// MARK: - Debug Settings

struct DebugSettingsView: View {
  @StateObject private var serverManager = ServerManager.shared
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry
  @State private var showServerTest = false
  @State private var showEndpointSettings = false

  private var activeConnectionStatus: ConnectionStatus {
    runtimeRegistry.activeConnectionStatus
  }

  private var endpointCount: Int {
    runtimeRegistry.runtimes.count
  }

  private var enabledEndpointCount: Int {
    runtimeRegistry.runtimes.filter(\.endpoint.isEnabled).count
  }

  private var connectedEndpointCount: Int {
    runtimeRegistry.runtimes.filter { runtime in
      let status = runtimeRegistry.connectionStatusByEndpointId[runtime.endpoint.id] ?? runtime.connection.status
      if case .connected = status {
        return true
      }
      return false
    }.count
  }

  private var endpointStatusColor: Color {
    if enabledEndpointCount > 0, connectedEndpointCount == enabledEndpointCount {
      return Color.statusSuccess
    }
    if connectedEndpointCount > 0 {
      return Color.statusQuestion
    }
    return Color.statusPermission
  }

  private var endpointStatusText: String {
    if enabledEndpointCount == 0 {
      return "No enabled endpoints"
    }
    return "\(connectedEndpointCount) of \(enabledEndpointCount) enabled connected"
  }

  var body: some View {
    ScrollView {
      VStack(spacing: Spacing.xl) {
        SettingsSection(title: "ENDPOINTS", icon: "network") {
          HStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right")
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(endpointStatusColor)

            VStack(alignment: .leading, spacing: 3) {
              Text(endpointStatusText)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
              Text("\(endpointCount) total endpoints configured")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.textTertiary)
            }

            Spacer()

            Button("Manage Endpoints") {
              showEndpointSettings = true
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accent)
          }

          Text(
            "Choose one control-plane endpoint for this Mac while keeping additional endpoints connected in parallel."
          )
          .font(.system(size: 11))
          .foregroundStyle(Color.textTertiary)
        }

        // Server install state
        SettingsSection(title: "SERVER", icon: "server.rack") {
          HStack {
            Circle()
              .fill(installStateColor)
              .frame(width: 8, height: 8)

            Text(installStateLabel)
              .font(.system(size: 13))

            Spacer()

            serverActionButtons
          }

          if let error = serverManager.installError {
            Text(error)
              .font(.system(size: 11))
              .foregroundStyle(Color.statusError)
          }
        }

        // WebSocket connection
        SettingsSection(title: "CONNECTION", icon: "bolt.horizontal") {
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

          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text("Binary")
                .font(.system(size: 13))
              Text(serverManager.findServerBinary() ?? "Not found")
                .font(.system(size: 11).monospaced())
                .foregroundStyle(Color.textTertiary)
            }

            Spacer()

            Button("Refresh") {
              Task { await serverManager.refreshState() }
            }
            .buttonStyle(.bordered)
          }
        }
      }
      .padding(Spacing.xl)
    }
    .sheet(isPresented: $showServerTest) {
      ServerTestView()
    }
    .sheet(isPresented: $showEndpointSettings) {
      ServerSettingsSheet()
        .environment(runtimeRegistry)
    }
  }

  // MARK: - Server State

  private var installStateColor: Color {
    switch serverManager.installState {
      case .running: .statusSuccess
      case .installed: .statusReply
      case .remote: .statusQuestion
      case .notConfigured: .statusEnded
      case .unknown: .statusEnded
    }
  }

  private var installStateLabel: String {
    switch serverManager.installState {
      case .running: "Server Running"
      case .installed: "Installed (Stopped)"
      case .remote: "Remote Configured"
      case .notConfigured: "Not Configured"
      case .unknown: "Checking..."
    }
  }

  @ViewBuilder
  private var serverActionButtons: some View {
    #if os(macOS)
      switch serverManager.installState {
        case .running:
        HStack(spacing: 8) {
          Button("Stop") {
            Task { try? await serverManager.stopService() }
          }
          .buttonStyle(.bordered)

          Button("Restart") {
            Task { try? await serverManager.restartService() }
          }
          .buttonStyle(.bordered)
        }

        case .installed:
        Button("Start") {
          Task {
            try? await serverManager.startService()
            if serverManager.installState == .running {
              runtimeRegistry.startEnabledRuntimes()
            }
          }
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.accent)

        case .notConfigured:
        Button("Install") {
          Task {
            try? await serverManager.install()
            if serverManager.installState == .running {
              runtimeRegistry.startEnabledRuntimes()
            }
          }
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.accent)
        .disabled(serverManager.isInstalling)

        case .remote, .unknown:
        EmptyView()
      }
    #endif
  }

  private var connectionColor: Color {
    switch activeConnectionStatus {
      case .connected:
        .statusSuccess
      case .connecting:
        .statusQuestion
      case .disconnected:
        .statusEnded
      case .failed:
        .statusError
    }
  }

  private var connectionText: String {
    switch activeConnectionStatus {
      case .connected:
        "Connected"
      case .connecting:
        "Connecting..."
      case .disconnected:
        "Disconnected"
      case let .failed(reason):
        "Failed: \(reason)"
    }
  }
}

// MARK: - Diagnostics Settings

struct DiagnosticsSettingsView: View {
  var body: some View {
    ScrollView {
      VStack(spacing: Spacing.xl) {
        SettingsSection(title: "LOGS", icon: "doc.text") {
          VStack(alignment: .leading, spacing: 12) {
            diagnosticsPathRow(
              label: "Codex Log",
              path: "~/.orbitdock/logs/codex.log"
            ) {
              reveal(PlatformPaths.orbitDockLogsDirectory)
            }

            diagnosticsPathRow(
              label: "Server Log",
              path: "~/.orbitdock/logs/server.log"
            ) {
              reveal(PlatformPaths.orbitDockLogsDirectory)
            }

            diagnosticsPathRow(
              label: "CLI Log",
              path: "~/.orbitdock/cli.log"
            ) {
              reveal(PlatformPaths.orbitDockBaseDirectory)
            }
          }
        }

        SettingsSection(title: "DATABASE", icon: "cylinder") {
          diagnosticsPathRow(
            label: "OrbitDock Database",
            path: "~/.orbitdock/orbitdock.db"
          ) {
            reveal(PlatformPaths.orbitDockBaseDirectory)
          }
        }
      }
      .padding(Spacing.xl)
    }
  }

  private func diagnosticsPathRow(label: String, path: String, action: @escaping () -> Void) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: 4) {
        Text(label)
          .font(.system(size: 13))
        Text(path)
          .font(.system(size: 11).monospaced())
          .foregroundStyle(Color.textTertiary)
      }

      Spacer()

      Button("Open in Finder", action: action)
        .buttonStyle(.bordered)
    }
  }

  private func reveal(_ url: URL) {
    _ = Platform.services.revealInFileBrowser(url.path)
  }
}

// MARK: - Preview

#Preview {
  SettingsView()
    .environment(ServerRuntimeRegistry.shared)
    .preferredColorScheme(.dark)
}
