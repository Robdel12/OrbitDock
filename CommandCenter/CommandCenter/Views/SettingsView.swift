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
      }
      .padding(.horizontal, 16)
      .padding(.top, 16)
      .padding(.bottom, 12)

      Divider()
        .foregroundStyle(Color.panelBorder)

      // Content
      Group {
        if selectedTab == 0 {
          GeneralSettingsView()
        } else {
          NotificationSettingsView()
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(width: 480, height: 340)
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

// MARK: - Preview

#Preview {
  SettingsView()
    .preferredColorScheme(.dark)
}
