import SwiftUI

struct SettingsOpenAiNamingSection: View {
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry
  @Bindable var model: SettingsOpenAiNamingModel

  private var activeRuntime: ServerRuntime? {
    runtimeRegistry.primaryRuntime ?? runtimeRegistry.activeRuntime
  }

  private var presentation: SettingsOpenAiNamingPresentation {
    SettingsGeneralPlanning.openAiNamingPresentation(
      status: model.status,
      isReplacingKey: model.isReplacingKey,
      keySaved: model.keySaved
    )
  }

  var body: some View {
    SettingsSection(title: "AI NAMING", icon: "sparkles") {
      VStack(alignment: .leading, spacing: Spacing.md) {
        statusRow

        Divider()
          .foregroundStyle(Color.panelBorder)

        VStack(alignment: .leading, spacing: Spacing.sm) {
          Text(presentation.introCopy)
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textSecondary)

          if presentation.showsStoredKey {
            storedKeyRow
          } else {
            editingRow
          }

          if presentation.showsSavedMessage {
            Text("Key encrypted and saved — new sessions will be auto-named.")
              .font(.system(size: TypeScale.meta))
              .foregroundStyle(Color.textTertiary)
          }
        }
      }
    }
    .task(id: activeRuntime?.endpoint.id) {
      refreshStatus()
    }
  }

  @ViewBuilder
  private var statusRow: some View {
    HStack {
      if presentation.showsProgress {
        ProgressView()
          .controlSize(.small)
      } else if let iconName = presentation.statusIcon {
        Image(systemName: iconName)
          .foregroundStyle(statusColor(for: presentation.statusTone))
      }

      Text(presentation.statusText)
        .font(.system(size: TypeScale.body))
        .foregroundStyle(presentation.showsProgress ? Color.textSecondary : Color.textPrimary)

      Spacer()

      if presentation.showsEncryptedBadge {
        Image(systemName: "lock.shield.fill")
          .font(.system(size: TypeScale.meta))
          .foregroundStyle(Color.textTertiary)
        Text("Encrypted")
          .font(.system(size: TypeScale.meta, weight: .medium))
          .foregroundStyle(Color.textTertiary)
      }
    }
  }

  private var storedKeyRow: some View {
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
        model.startReplacing()
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
  }

  private var editingRow: some View {
    HStack(spacing: Spacing.sm) {
      SecureField("sk-...", text: $model.keyInput)
        .textFieldStyle(.roundedBorder)
        .font(.system(size: TypeScale.caption).monospaced())

      Button {
        saveKey()
      } label: {
        HStack(spacing: Spacing.xs) {
          Image(systemName: model.keySaved ? "checkmark" : "arrow.up.circle")
            .font(.system(size: TypeScale.meta, weight: .medium))
          Text(model.keySaved ? "Saved" : "Save")
            .font(.system(size: TypeScale.caption, weight: .medium))
        }
        .foregroundStyle(model.keySaved ? Color.feedbackPositive : Color.backgroundPrimary)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 7)
        .background(
          model.keySaved ? Color.feedbackPositive.opacity(0.2) : Color.accent,
          in: RoundedRectangle(cornerRadius: Radius.md)
        )
      }
      .buttonStyle(.plain)
      .disabled(model.keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

      if model.isReplacingKey {
        Button {
          model.cancelReplacing()
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
  }

  private func refreshStatus() {
    let runtime = activeRuntime
    model.refresh(
      activeRuntimeId: runtime?.endpoint.id,
      checkStatus: {
        guard let runtime else { return false }
        return try await runtime.clients.config.checkOpenAiKeyStatus()
      }
    )
  }

  private func saveKey() {
    let runtime = activeRuntime
    model.save(
      using: { key in
        guard let runtime else { return }
        try await runtime.clients.config.setOpenAiKey(key)
      },
      thenRefresh: {
        await MainActor.run {
          refreshStatus()
        }
      }
    )
  }

  private func statusColor(for tone: SettingsSectionTone) -> Color {
    switch tone {
      case .neutral:
        return .textSecondary
      case .positive:
        return .feedbackPositive
      case .warning:
        return .statusPermission
    }
  }
}
