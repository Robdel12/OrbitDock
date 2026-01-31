//
//  SettingsView.swift
//  OrbitDock
//
//  Settings/Preferences window
//

import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            NotificationSettingsView()
                .tabItem {
                    Label("Notifications", systemImage: "bell.badge")
                }
        }
        .frame(width: 450, height: 320)
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
        Form {
            Section {
                Picker("Default Editor", selection: $preferredEditor) {
                    ForEach(editors, id: \.id) { editor in
                        Label(editor.name, systemImage: editor.icon)
                            .tag(editor.id)
                    }
                }
                .pickerStyle(.menu)

                Text("Used when clicking project paths to open in your editor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Editor", systemImage: "chevron.left.forwardslash.chevron.right")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

// MARK: - Notification Settings

struct NotificationSettingsView: View {
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
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
        Form {
            Section {
                Toggle("Enable Notifications", isOn: $notificationsEnabled)

                Text("Receive alerts when sessions need attention (waiting for input or permission).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Alerts", systemImage: "bell.badge")
            }

            Section {
                HStack {
                    Picker("Sound", selection: $notificationSound) {
                        ForEach(systemSounds, id: \.id) { sound in
                            Text(sound.name).tag(sound.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 200)

                    Spacer()

                    Button {
                        previewSound()
                    } label: {
                        Image(systemName: "speaker.wave.2")
                            .font(.system(size: 14))
                            .foregroundStyle(notificationSound == "none" ? .secondary : Color.accent)
                            .frame(width: 32, height: 32)
                            .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .disabled(notificationSound == "none")
                    .help("Preview sound")
                }

                Text("Plays when a session needs your attention.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Sound", systemImage: "speaker.wave.2")
            }
            .disabled(!notificationsEnabled)
            .opacity(notificationsEnabled ? 1 : 0.5)
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private func previewSound() {
        guard notificationSound != "none" else { return }

        if notificationSound == "default" {
            NSSound.beep()
        } else if let sound = NSSound(named: NSSound.Name(notificationSound)) {
            sound.play()
        }
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
}
