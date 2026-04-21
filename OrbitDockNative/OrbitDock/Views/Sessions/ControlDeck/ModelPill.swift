import SwiftUI

struct ModelPill: View {
  let currentModel: String?
  var availableModels: [String] = []
  var size: CodexApprovalPill.PillSize = .regular
  var onUpdate: ((String) -> Void)?
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @State private var showPopover = false
  @State private var customModelInput = ""

  private var displayLabel: String {
    guard let model = currentModel, !model.isEmpty else { return "Default" }
    // Shorten common model names for compact display
    return model
      .replacingOccurrences(of: "claude-", with: "")
      .replacingOccurrences(of: "-20251001", with: "")
  }

  private var isCustomModel: Bool {
    guard let model = currentModel, !model.isEmpty else { return false }
    return !availableModels.contains(model)
  }

  var body: some View {
    Button {
      showPopover.toggle()
      customModelInput = isCustomModel ? (currentModel ?? "") : ""
    } label: {
      HStack(spacing: size.spacing) {
        Image(systemName: "cpu")
          .font(.system(size: size.iconFontSize, weight: .semibold))
        Text(displayLabel)
          .font(.system(size: size.textFontSize, weight: .semibold))
          .lineLimit(1)
      }
      .foregroundStyle(Color.textSecondary)
      .padding(.horizontal, size.horizontalPadding)
      .padding(.vertical, size.verticalPadding)
      .frame(height: size.height)
      .background(Color.backgroundTertiary.opacity(0.72), in: Capsule())
    }
    .buttonStyle(.plain)
    .fixedSize()
    .platformPopover(isPresented: $showPopover) {
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.md) {
          VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Model")
              .font(.system(size: TypeScale.subhead, weight: .semibold))
              .foregroundStyle(Color.textPrimary)

            Text("Choose a model for this session or enter a custom model name.")
              .font(.system(size: TypeScale.caption))
              .foregroundStyle(Color.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }

          VStack(alignment: .leading, spacing: Spacing.xxs) {
            ForEach(availableModels, id: \.self) { model in
              modelRow(model: model, isSelected: currentModel == model)
            }
          }

          Divider()
            .padding(.vertical, Spacing.xs)

          VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Custom Model")
              .font(.system(size: TypeScale.caption, weight: .semibold))
              .foregroundStyle(Color.textSecondary)

            HStack(spacing: Spacing.sm_) {
              TextField("e.g., claude-opus-4-6", text: $customModelInput)
                .font(.system(size: TypeScale.body, design: .monospaced))
                .textFieldStyle(.plain)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.sm_)
                .background(
                  RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .fill(Color.backgroundTertiary)
                )

              Button {
                let trimmed = customModelInput.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                onUpdate?(trimmed)
                showPopover = false
              } label: {
                Text("Apply")
                  .font(.system(size: TypeScale.caption, weight: .semibold))
                  .foregroundStyle(customModelInput.isEmpty ? Color.textQuaternary : Color.backgroundPrimary)
                  .padding(.horizontal, Spacing.md)
                  .padding(.vertical, Spacing.sm_)
                  .background(
                    customModelInput.isEmpty ? Color.backgroundTertiary : Color.accent,
                    in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                  )
              }
              .buttonStyle(.plain)
              .disabled(customModelInput.isEmpty)
            }
          }
        }
        .padding(Spacing.lg)
      }
      .platformSheetNavigationTitle("Model")
        .ifMacOS { $0.frame(width: 320) }
        .background(Color.backgroundSecondary)
    }
  }

  private func modelRow(model: String, isSelected: Bool) -> some View {
    Button {
      onUpdate?(model)
      showPopover = false
    } label: {
      HStack(spacing: Spacing.sm) {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text(modelDisplayName(model))
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(Color.textPrimary)

          Text(model)
            .font(.system(size: TypeScale.caption, design: .monospaced))
            .foregroundStyle(Color.textTertiary)
        }

        Spacer(minLength: Spacing.sm)

        if isSelected {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.accent)
        }
      }
      .padding(.vertical, Spacing.sm_)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func modelDisplayName(_ model: String) -> String {
    switch model {
      case "claude-opus-4-6": "Opus 4.6"
      case "claude-sonnet-4-6": "Sonnet 4.6"
      case "claude-haiku-4-5": "Haiku 4.5"
      default: model.replacingOccurrences(of: "claude-", with: "").capitalized
    }
  }
}
