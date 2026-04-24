import SwiftUI

struct ModelPill: View {
  let currentModel: String?
  var availableModels: [String] = []
  var size: CodexApprovalPill.PillSize = .regular
  var onUpdate: ((String) -> Void)?
  @State private var showPopover = false
  @State private var customModelInput = ""
  @State private var showCustomField = false

  private var currentDescriptor: ModelDescriptor? {
    ModelCatalog.describe(currentModel)
  }

  private var isCustomSelection: Bool {
    guard let model = currentModel, !model.isEmpty else { return false }
    return !availableModels.contains(model)
  }

  private var pillLabel: String {
    currentDescriptor?.displayName ?? "Default"
  }

  private var pillTint: Color {
    currentDescriptor?.tint ?? .textTertiary
  }

  private var trimmedCustom: String {
    customModelInput.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    Button(action: togglePopover) {
      HStack(spacing: size.spacing) {
        Image(systemName: "cpu")
          .font(.system(size: size.iconFontSize, weight: .semibold))
          .foregroundStyle(pillTint)
        Text(pillLabel)
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
      popoverContent
        .platformSheetNavigationTitle("Model")
        .ifMacOS { $0.frame(width: 340) }
        .background(Color.backgroundSecondary)
    }
  }

  private func togglePopover() {
    let willShow = !showPopover
    showPopover = willShow
    guard willShow else { return }
    customModelInput = isCustomSelection ? (currentModel ?? "") : ""
    showCustomField = isCustomSelection
  }

  // MARK: - Popover body

  private var popoverContent: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.md) {
        header

        if isCustomSelection, let descriptor = currentDescriptor {
          currentCustomBanner(descriptor)
        }

        groupedList

        customFooter
      }
      .padding(Spacing.lg)
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text("Model")
        .font(.system(size: TypeScale.subhead, weight: .semibold))
        .foregroundStyle(Color.textPrimary)

      Text("Pick a model for this session. Custom IDs are passed straight through.")
        .font(.system(size: TypeScale.caption))
        .foregroundStyle(Color.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func currentCustomBanner(_ descriptor: ModelDescriptor) -> some View {
    HStack(spacing: Spacing.sm) {
      VStack(alignment: .leading, spacing: Spacing.xxs) {
        Text("Custom in use")
          .font(.system(size: TypeScale.mini, weight: .bold))
          .foregroundStyle(Color.textTertiary)
          .textCase(.uppercase)
          .tracking(0.6)
        Text(descriptor.id)
          .font(.system(size: TypeScale.caption, design: .monospaced))
          .foregroundStyle(Color.textPrimary)
          .lineLimit(1)
          .truncationMode(.middle)
      }

      Spacer(minLength: Spacing.sm)

      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: TypeScale.caption, weight: .semibold))
        .foregroundStyle(descriptor.tint)
    }
    .padding(Spacing.sm)
    .background(
      descriptor.tint.opacity(OpacityTier.light),
      in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .strokeBorder(descriptor.tint.opacity(OpacityTier.medium), lineWidth: 1)
    )
  }

  private var groupedList: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      ForEach(ModelCatalog.grouped(availableModels)) { group in
        VStack(alignment: .leading, spacing: Spacing.xxs) {
          sectionHeader(for: group.family)

          VStack(alignment: .leading, spacing: 1) {
            ForEach(group.descriptors) { descriptor in
              modelRow(descriptor, isSelected: currentModel == descriptor.id)
            }
          }
        }
      }
    }
  }

  private func sectionHeader(for family: ModelFamily) -> some View {
    Text(family.rawValue)
      .font(.system(size: TypeScale.mini, weight: .bold))
      .foregroundStyle(Color.textTertiary)
      .textCase(.uppercase)
      .tracking(0.6)
      .padding(.horizontal, Spacing.xs)
      .padding(.bottom, Spacing.xxs)
  }

  private func modelRow(_ descriptor: ModelDescriptor, isSelected: Bool) -> some View {
    Button {
      onUpdate?(descriptor.id)
      showPopover = false
    } label: {
      HStack(spacing: Spacing.sm) {
        VStack(alignment: .leading, spacing: 1) {
          Text(descriptor.displayName)
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(Color.textPrimary)
          Text(descriptor.id)
            .font(.system(size: TypeScale.mini, design: .monospaced))
            .foregroundStyle(Color.textTertiary)
            .lineLimit(1)
            .truncationMode(.middle)
        }

        Spacer(minLength: Spacing.sm)

        Image(systemName: "checkmark")
          .font(.system(size: TypeScale.caption, weight: .bold))
          .foregroundStyle(descriptor.tint)
          .opacity(isSelected ? 1 : 0)
      }
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.sm_)
      .background(
        isSelected ? Color.surfaceSelected : Color.clear,
        in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  // MARK: - Custom model footer

  @ViewBuilder
  private var customFooter: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Divider()
        .background(Color.panelBorder)

      Button {
        withAnimation(Motion.standard) { showCustomField.toggle() }
      } label: {
        HStack(spacing: Spacing.xs) {
          Image(systemName: showCustomField ? "chevron.down" : "chevron.right")
            .font(.system(size: TypeScale.mini, weight: .bold))
          Text(showCustomField ? "Hide custom model" : "Use a custom model ID")
            .font(.system(size: TypeScale.caption, weight: .semibold))
        }
        .foregroundStyle(Color.textSecondary)
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, Spacing.xxs)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if showCustomField {
        HStack(spacing: Spacing.sm_) {
          TextField("e.g. claude-opus-4-6", text: $customModelInput)
            .font(.system(size: TypeScale.body, design: .monospaced))
            .textFieldStyle(.plain)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.sm_)
            .background(
              RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .fill(Color.backgroundTertiary)
            )
            .overlay(
              RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(Color.panelBorder, lineWidth: 1)
            )
            .onSubmit(submitCustom)

          Button(action: submitCustom) {
            Text("Apply")
              .font(.system(size: TypeScale.caption, weight: .semibold))
              .foregroundStyle(
                trimmedCustom.isEmpty ? Color.textQuaternary : Color.backgroundPrimary
              )
              .padding(.horizontal, Spacing.md)
              .padding(.vertical, Spacing.sm_)
              .background(
                trimmedCustom.isEmpty ? Color.backgroundTertiary : Color.accent,
                in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
              )
          }
          .buttonStyle(.plain)
          .disabled(trimmedCustom.isEmpty)
        }
      }
    }
  }

  private func submitCustom() {
    guard !trimmedCustom.isEmpty else { return }
    onUpdate?(trimmedCustom)
    showPopover = false
  }
}
