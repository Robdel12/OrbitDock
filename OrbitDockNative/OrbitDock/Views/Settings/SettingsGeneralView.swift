import SwiftUI

struct GeneralSettingsView: View {
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry
  @AppStorage("preferredEditor") private var preferredEditor: String = ""
  @AppStorage("localDictationEnabled") private var localDictationEnabled = true
  @State private var openAiKey: String = ""
  @State private var openAiKeySaved = false
  @State private var openAiKeyStatus: OpenAiKeyStatus = .checking
  @State private var isReplacingKey = false
  @State private var openAiKeyStatusRequestId = UUID()

  private enum OpenAiKeyStatus {
    case checking, configured, notConfigured
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
          VStack(alignment: .leading, spacing: Spacing.md_) {
            HStack {
              Text("Default Editor")
                .font(.system(size: TypeScale.body))

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
              .font(.system(size: TypeScale.meta))
              .foregroundStyle(Color.textTertiary)
          }
        }

        SettingsSection(title: "AI NAMING", icon: "sparkles") {
          VStack(alignment: .leading, spacing: Spacing.md) {
            HStack {
              switch openAiKeyStatus {
                case .checking:
                  ProgressView()
                    .controlSize(.small)
                  Text("Checking...")
                    .font(.system(size: TypeScale.body))
                    .foregroundStyle(Color.textSecondary)
                case .configured:
                  Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.feedbackPositive)
                  Text("API key configured")
                    .font(.system(size: TypeScale.body))
                  Spacer()
                  Image(systemName: "lock.shield.fill")
                    .font(.system(size: TypeScale.meta))
                    .foregroundStyle(Color.textTertiary)
                  Text("Encrypted")
                    .font(.system(size: TypeScale.meta, weight: .medium))
                    .foregroundStyle(Color.textTertiary)
                case .notConfigured:
                  Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(Color.statusPermission)
                  Text("No API key set")
                    .font(.system(size: TypeScale.body))
              }
              Spacer()
            }

            Divider()
              .foregroundStyle(Color.panelBorder)

            VStack(alignment: .leading, spacing: Spacing.sm) {
              if openAiKeyStatus == .configured, !isReplacingKey {
                Text("OpenAI API key for auto-naming sessions from first prompts.")
                  .font(.system(size: TypeScale.caption))
                  .foregroundStyle(Color.textSecondary)

                HStack(spacing: Spacing.sm) {
                  HStack(spacing: Spacing.sm_) {
                    Image(systemName: "key.fill")
                      .font(.system(size: TypeScale.micro))
                      .foregroundStyle(Color.textTertiary)
                    Text("sk-\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}")
                      .font(.system(size: TypeScale.caption).monospaced())
                      .foregroundStyle(Color.textSecondary)
                  }
                  .padding(.horizontal, Spacing.md_)
                  .padding(.vertical, 7)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .background(
                    Color.backgroundTertiary,
                    in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                  )
                  .overlay(
                    RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                      .strokeBorder(Color.panelBorder, lineWidth: 1)
                  )

                  Button {
                    isReplacingKey = true
                  } label: {
                    Text("Replace")
                      .font(.system(size: TypeScale.caption, weight: .medium))
                      .foregroundStyle(Color.accent)
                      .padding(.horizontal, Spacing.md)
                      .padding(.vertical, 7)
                      .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: Radius.md))
                  }
                  .buttonStyle(.plain)
                }
              } else {
                Text(isReplacingKey
                  ? "Enter a new key to replace the existing one."
                  : "OpenAI API key for auto-naming sessions from first prompts.")
                  .font(.system(size: TypeScale.caption))
                  .foregroundStyle(Color.textSecondary)

                HStack(spacing: Spacing.sm) {
                  SecureField("sk-...", text: $openAiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: TypeScale.caption).monospaced())

                  Button {
                    saveOpenAiKey()
                  } label: {
                    HStack(spacing: Spacing.xs) {
                      Image(systemName: openAiKeySaved ? "checkmark" : "arrow.up.circle")
                        .font(.system(size: TypeScale.meta, weight: .medium))
                      Text(openAiKeySaved ? "Saved" : "Save")
                        .font(.system(size: TypeScale.caption, weight: .medium))
                    }
                    .foregroundStyle(openAiKeySaved ? Color.feedbackPositive : Color.backgroundPrimary)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 7)
                    .background(
                      openAiKeySaved ? Color.feedbackPositive.opacity(0.2) : Color.accent,
                      in: RoundedRectangle(cornerRadius: Radius.md)
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
                        .font(.system(size: TypeScale.caption, weight: .medium))
                        .foregroundStyle(Color.textSecondary)
                        .padding(.horizontal, Spacing.md_)
                        .padding(.vertical, 7)
                    }
                    .buttonStyle(.plain)
                  }
                }

                if openAiKeySaved {
                  Text("Key encrypted and saved — new sessions will be auto-named.")
                    .font(.system(size: TypeScale.meta))
                    .foregroundStyle(Color.textTertiary)
                }
              }
            }
          }
        }

        SettingsSection(title: "LOCAL DICTATION", icon: "waveform.badge.mic") {
          VStack(alignment: .leading, spacing: Spacing.lg_) {
            VStack(alignment: .leading, spacing: Spacing.sm_) {
              Toggle(isOn: $localDictationEnabled) {
                Text("Enable Dictation")
                  .font(.system(size: TypeScale.body))
              }
              .toggleStyle(.switch)
              .tint(Color.accent)
              .disabled(currentDictationAvailability == .unavailable)

              Text(localDictationIntroCopy)
                .font(.system(size: TypeScale.meta))
                .foregroundStyle(Color.textTertiary)
            }

            Divider()
              .foregroundStyle(Color.panelBorder)

            HStack(spacing: Spacing.sm) {
              Image(systemName: currentDictationEngineIcon)
                .foregroundStyle(currentDictationEngineColor)
              Text(currentDictationEngineTitle)
                .font(.system(size: TypeScale.body))
              Spacer()
              if currentDictationAvailability == .available {
                Text("Live")
                  .font(.system(size: TypeScale.meta, weight: .medium))
                  .foregroundStyle(Color.textTertiary)
                  .padding(.horizontal, Spacing.sm)
                  .padding(.vertical, Spacing.xxs)
                  .background(Color.surfaceHover, in: Capsule())
              }
            }

            Text(currentDictationEngineDescription)
              .font(.system(size: TypeScale.meta))
              .foregroundStyle(Color.textTertiary)
          }
        }
      }
      .padding(Spacing.xl)
    }
    .onAppear {
      checkOpenAiKeyStatus()
    }
  }

  private var currentDictationAvailability: LocalDictationAvailability {
    LocalDictationAvailabilityResolver.current
  }

  private var localDictationIntroCopy: String {
    "OrbitDock uses Apple's on-device Speech framework for live dictation on iOS 26 and macOS 26. The system may install speech assets the first time you use it."
  }

  private var currentDictationEngineTitle: String {
    switch currentDictationAvailability {
      case .available:
        "Apple Speech"
      case .unavailable:
        "Dictation unavailable"
    }
  }

  private var currentDictationEngineDescription: String {
    switch currentDictationAvailability {
      case .available:
        "Dictation updates the composer live as you speak and stays fully on-device."
      case .unavailable:
        "Dictation requires iOS 26 or macOS 26 because OrbitDock now uses Apple's new Speech framework directly."
    }
  }

  private var currentDictationEngineIcon: String {
    switch currentDictationAvailability {
      case .available:
        "apple.logo"
      case .unavailable:
        "xmark.circle.fill"
    }
  }

  private var currentDictationEngineColor: Color {
    switch currentDictationAvailability {
      case .available:
        .accent
      case .unavailable:
        .statusPermission
    }
  }

  private func saveOpenAiKey() {
    guard let clients = runtimeRegistry.primaryRuntime?.clients ?? runtimeRegistry.activeRuntime?.clients else { return }
    Task {
      try? await clients.config.setOpenAiKey(openAiKey)
    }
    openAiKeySaved = true
    openAiKey = ""
    isReplacingKey = false
    checkOpenAiKeyStatus()
  }

  private func checkOpenAiKeyStatus() {
    guard let runtime = runtimeRegistry.primaryRuntime ?? runtimeRegistry.activeRuntime else {
      openAiKeyStatus = .notConfigured
      return
    }

    openAiKeyStatus = .checking
    let endpointId = runtime.endpoint.id
    let clients = runtime.clients
    let requestId = UUID()
    openAiKeyStatusRequestId = requestId

    Task { @MainActor in
      do {
        let configured = try await clients.config.checkOpenAiKeyStatus()
        guard openAiKeyStatusRequestId == requestId,
              (runtimeRegistry.primaryRuntime ?? runtimeRegistry.activeRuntime)?.endpoint.id == endpointId
        else { return }
        openAiKeyStatus = configured ? .configured : .notConfigured
      } catch {
        guard openAiKeyStatusRequestId == requestId,
              (runtimeRegistry.primaryRuntime ?? runtimeRegistry.activeRuntime)?.endpoint.id == endpointId
        else { return }
        openAiKeyStatus = .notConfigured
      }
    }
  }
}
