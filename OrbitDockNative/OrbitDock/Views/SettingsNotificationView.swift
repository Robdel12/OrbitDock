import SwiftUI
import UserNotifications

struct NotificationSettingsView: View {
  @Environment(NotificationManager.self) private var notificationManager
  @AppStorage("notificationsEnabled") private var notificationsEnabled = true
  @AppStorage("notifyOnWorkComplete") private var notifyOnWorkComplete = true
  @AppStorage("notificationSound") private var notificationSound = "default"
  #if os(iOS)
    @AppStorage("hapticFeedbackLevel") private var hapticFeedbackLevel = AppHapticLevel.minimal.rawValue
  #endif

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
          VStack(alignment: .leading, spacing: Spacing.lg_) {
            VStack(alignment: .leading, spacing: Spacing.sm_) {
              Toggle(isOn: $notificationsEnabled) {
                Text("Enable Notifications")
                  .font(.system(size: TypeScale.body))
              }
              .toggleStyle(.switch)
              .tint(Color.accent)

              Text("Master switch for all OrbitDock notifications.")
                .font(.system(size: TypeScale.meta))
                .foregroundStyle(Color.textTertiary)
            }

            Divider()
              .foregroundStyle(Color.panelBorder)

            VStack(alignment: .leading, spacing: Spacing.sm_) {
              Toggle(isOn: $notifyOnWorkComplete) {
                Text("Notify When Agent Finishes")
                  .font(.system(size: TypeScale.body))
              }
              .toggleStyle(.switch)
              .tint(Color.accent)
              .disabled(!notificationsEnabled)

              Text("Alert when a session stops working and is ready for input.")
                .font(.system(size: TypeScale.meta))
                .foregroundStyle(Color.textTertiary)
            }
            .opacity(notificationsEnabled ? 1 : 0.5)
          }
        }

        SettingsSection(title: "SOUND", icon: "speaker.wave.2") {
          VStack(alignment: .leading, spacing: Spacing.md_) {
            HStack {
              Text("Notification Sound")
                .font(.system(size: TypeScale.body))

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
                  .font(.system(size: TypeScale.micro, weight: .semibold))
                  .foregroundStyle(notificationSound == "none" ? Color.textTertiary : Color.accent)
                  .frame(width: 28, height: 28)
                  .background(
                    Color.backgroundTertiary,
                    in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                  )
                  .overlay(
                    RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                      .strokeBorder(Color.panelBorder, lineWidth: 1)
                  )
              }
              .buttonStyle(.plain)
              .disabled(notificationSound == "none")
              .help("Preview sound")
            }

            Text("Plays when a session needs your attention.")
              .font(.system(size: TypeScale.meta))
              .foregroundStyle(Color.textTertiary)
          }
        }
        .opacity(notificationsEnabled ? 1 : 0.5)
        .allowsHitTesting(notificationsEnabled)

        #if os(iOS)
          SettingsSection(title: "HAPTICS", icon: "iphone.radiowaves.left.and.right") {
            VStack(alignment: .leading, spacing: Spacing.md_) {
              Picker("Haptic Feedback", selection: $hapticFeedbackLevel) {
                ForEach(AppHapticLevel.allCases) { level in
                  Text(level.title).tag(level.rawValue)
                }
              }
              .pickerStyle(.segmented)

              Text(selectedHapticLevel.detail)
                .font(.system(size: TypeScale.meta))
                .foregroundStyle(Color.textTertiary)
            }
          }
        #endif

        Button {
          sendTestNotification()
        } label: {
          HStack(spacing: Spacing.sm_) {
            Image(systemName: "bell.badge")
              .font(.system(size: TypeScale.meta, weight: .medium))
            Text("Send Test Notification")
              .font(.system(size: TypeScale.caption, weight: .medium))
          }
          .foregroundStyle(notificationsEnabled ? Color.accent : Color.textTertiary)
          .padding(.horizontal, Spacing.lg_)
          .padding(.vertical, Spacing.sm)
          .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: Radius.ml, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
              .strokeBorder(Color.panelBorder, lineWidth: 1)
          )
        }
        .buttonStyle(.plain)
        .disabled(!notificationsEnabled)
        .help("Send a test notification to verify your settings")
      }
      .padding(Spacing.xl)
    }
    #if os(iOS)
    .onChange(of: hapticFeedbackLevel) { _, newValue in
      guard let level = AppHapticLevel(rawValue: newValue), level != .off else { return }
      Platform.services.playHaptic(level == .full ? .success : .action)
    }
    #endif
  }

  #if os(iOS)
    private var selectedHapticLevel: AppHapticLevel {
      AppHapticLevel(rawValue: hapticFeedbackLevel) ?? .minimal
    }
  #endif

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
    notificationManager.sendTestNotification(soundID: notificationSound)
  }
}
