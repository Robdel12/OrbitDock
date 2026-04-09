import SwiftUI

struct SessionPresetRow: View {
  let provider: SessionProvider
  let presets: [SessionPreset]
  let onSelect: (SessionPreset) -> Void
  let onSave: (String) -> Void
  let onDelete: (UUID) -> Void

  @State private var isSaving = false
  @State private var presetName = ""

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      if !presets.isEmpty {
        presetList
      }

      if isSaving {
        saveField
      } else {
        saveButton
      }
    }
  }

  // MARK: - Preset List

  private var presetList: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      ForEach(presets) { preset in
        presetCard(preset)
      }
    }
  }

  private func presetCard(_ preset: SessionPreset) -> some View {
    Button {
      onSelect(preset)
    } label: {
      HStack(spacing: Spacing.sm) {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text(preset.name)
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(Color.textPrimary)

          Text(configSummary(preset.configuration))
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textTertiary)
            .lineLimit(1)
        }

        Spacer(minLength: Spacing.sm)

        Menu {
          Button(role: .destructive) {
            onDelete(preset.id)
          } label: {
            Label("Delete", systemImage: "trash")
          }
        } label: {
          Image(systemName: "ellipsis")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.textQuaternary)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
      }
      .padding(.vertical, Spacing.sm)
      .padding(.horizontal, Spacing.md)
      .background(
        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
          .fill(Color.backgroundTertiary)
      )
      .overlay(
        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
          .stroke(provider.color.opacity(OpacityTier.light), lineWidth: 1)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .platformCursorOnHover()
  }

  // MARK: - Save Button

  private var saveButton: some View {
    Button {
      isSaving = true
      presetName = ""
    } label: {
      HStack(spacing: Spacing.sm_) {
        Image(systemName: "plus.circle.fill")
          .font(.system(size: 12, weight: .semibold))
        Text("Save current settings as preset")
          .font(.system(size: TypeScale.caption, weight: .medium))
      }
      .foregroundStyle(provider.color)
      .padding(.vertical, Spacing.sm_)
    }
    .buttonStyle(.plain)
    .platformCursorOnHover()
  }

  // MARK: - Save Field

  private var saveField: some View {
    HStack(spacing: Spacing.sm) {
      TextField("Preset name", text: $presetName)
        .textFieldStyle(.plain)
        .font(.system(size: TypeScale.body, weight: .medium))
        .onSubmit {
          commitSave()
        }

      Button {
        commitSave()
      } label: {
        Text("Save")
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.textQuaternary : Color.backgroundPrimary)
          .padding(.horizontal, Spacing.md)
          .padding(.vertical, Spacing.sm_)
          .background(
            Capsule()
              .fill(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.backgroundTertiary : provider.color)
          )
      }
      .buttonStyle(.plain)
      .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      .platformCursorOnHover()

      Button {
        isSaving = false
        presetName = ""
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(Color.textTertiary)
      }
      .buttonStyle(.plain)
      .platformCursorOnHover()
    }
    .padding(.vertical, Spacing.sm)
    .padding(.horizontal, Spacing.md)
    .background(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .fill(Color.backgroundTertiary)
    )
  }

  // MARK: - Helpers

  private func configSummary(_ configuration: SessionPresetConfiguration) -> String {
    switch configuration {
      case let .claude(config): config.summary
      case let .codex(config): config.summary
    }
  }

  private func commitSave() {
    let trimmed = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    onSave(trimmed)
    isSaving = false
    presetName = ""
  }
}
