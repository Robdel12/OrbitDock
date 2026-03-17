import SwiftUI

func missionInstrumentPanel(
  title: String,
  icon: String,
  description: String,
  isCompact: Bool,
  @ViewBuilder content: () -> some View
) -> some View {
  VStack(alignment: .leading, spacing: 0) {
    HStack(spacing: 0) {
      RoundedRectangle(cornerRadius: 1.5, style: .continuous)
        .fill(Color.accent)
        .frame(width: EdgeBar.width)
        .padding(.vertical, Spacing.sm)

      VStack(alignment: .leading, spacing: Spacing.xxs) {
        HStack(spacing: Spacing.sm_) {
          Image(systemName: icon)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Color.accent)
          Text(title)
            .font(.system(size: TypeScale.body, weight: .bold))
            .foregroundStyle(Color.textPrimary)
        }

        if !isCompact {
          Text(description)
            .font(.system(size: TypeScale.micro))
            .foregroundStyle(Color.textQuaternary)
        }
      }
      .padding(.leading, Spacing.md)
    }
    .padding(.horizontal, isCompact ? Spacing.md : Spacing.lg)
    .padding(.vertical, isCompact ? Spacing.sm : Spacing.md)

    Divider()
      .foregroundStyle(Color.surfaceBorder.opacity(OpacityTier.subtle))

    content()
      .padding(isCompact ? Spacing.md : Spacing.lg)
  }
  .fixedSize(horizontal: false, vertical: true)
  .background(
    RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
      .fill(Color.backgroundSecondary)
      .overlay(
        RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
          .strokeBorder(Color.surfaceBorder.opacity(OpacityTier.subtle), lineWidth: 1)
      )
  )
}

func missionSectionLabel(_ text: String) -> some View {
  Text(text.uppercased())
    .font(.system(size: TypeScale.micro, weight: .bold))
    .foregroundStyle(Color.textQuaternary)
    .tracking(0.6)
}

func missionCompactField(_ label: String, placeholder: String, text: Binding<String>) -> some View {
  VStack(alignment: .leading, spacing: Spacing.xs) {
    Text(label)
      .font(.system(size: TypeScale.micro, weight: .medium))
      .foregroundStyle(Color.textTertiary)

    TextField(placeholder, text: text)
      .textFieldStyle(.plain)
      .font(.system(size: TypeScale.caption, design: .monospaced))
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.sm_)
      .background(
        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
          .fill(Color.backgroundPrimary)
          .overlay(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
              .strokeBorder(Color.surfaceBorder, lineWidth: 1)
          )
      )
  }
}

func missionConcurrencyStepper(_ label: String, value: Binding<UInt32>, range: ClosedRange<UInt32>) -> some View {
  HStack(spacing: Spacing.md) {
    Text(label)
      .font(.system(size: TypeScale.micro, weight: .medium))
      .foregroundStyle(Color.textTertiary)

    Spacer()

    HStack(spacing: 0) {
      Button {
        if value.wrappedValue > range.lowerBound {
          value.wrappedValue -= 1
        }
      } label: {
        Image(systemName: "minus")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(value.wrappedValue > range.lowerBound ? Color.textSecondary : Color.textQuaternary)
          .frame(width: 28, height: 26)
          .background(Color.backgroundTertiary)
      }
      .buttonStyle(.plain)

      Text("\(value.wrappedValue)")
        .font(.system(size: TypeScale.caption, weight: .bold, design: .monospaced))
        .foregroundStyle(Color.textPrimary)
        .frame(width: 32, height: 26)
        .background(Color.backgroundPrimary)

      Button {
        if value.wrappedValue < range.upperBound {
          value.wrappedValue += 1
        }
      } label: {
        Image(systemName: "plus")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(value.wrappedValue < range.upperBound ? Color.textSecondary : Color.textQuaternary)
          .frame(width: 28, height: 26)
          .background(Color.backgroundTertiary)
      }
      .buttonStyle(.plain)
    }
    .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
        .strokeBorder(Color.surfaceBorder, lineWidth: 1)
    )
  }
}

func missionIntervalChip(
  _ label: String,
  seconds: UInt64,
  current: UInt64,
  action: @escaping () -> Void
) -> some View {
  Button(action: action) {
    SelectableOptionChip(
      label: label,
      isSelected: current == seconds
    )
  }
  .buttonStyle(.plain)
}

func missionModeButton(
  _ label: String,
  icon: String,
  value: String,
  selected: String,
  action: @escaping () -> Void
) -> some View {
  Button(action: action) {
    SelectableOptionChip(
      label: label,
      icon: icon,
      isSelected: selected == value
    )
  }
  .buttonStyle(.plain)
}

func missionEffortRow(_ label: String, binding: Binding<EffortLevel>) -> some View {
  VStack(alignment: .leading, spacing: Spacing.sm_) {
    missionSectionLabel(label)

    WrappingFlowLayout(spacing: Spacing.xs) {
      missionEffortChip(.default, binding: binding)
      missionEffortChip(.low, binding: binding)
      missionEffortChip(.medium, binding: binding)
      missionEffortChip(.high, binding: binding)
    }
  }
  .frame(maxWidth: .infinity, alignment: .leading)
}

func missionEffortChip(_ level: EffortLevel, binding: Binding<EffortLevel>) -> some View {
  let isSelected = binding.wrappedValue == level
  let tint = level == .default ? Color.accent : level.color

  return Button {
    binding.wrappedValue = level
  } label: {
    SelectableOptionChip(
      label: level.displayName,
      isSelected: isSelected,
      tint: tint
    )
  }
  .buttonStyle(.plain)
}

func missionProviderSubheader(_ name: String, icon: String, color: Color) -> some View {
  HStack(spacing: Spacing.sm_) {
    RoundedRectangle(cornerRadius: 1, style: .continuous)
      .fill(color)
      .frame(width: 2, height: 12)

    Image(systemName: icon)
      .font(.system(size: 10, weight: .bold))
      .foregroundStyle(color)
    Text(name)
      .font(.system(size: TypeScale.caption, weight: .bold))
      .foregroundStyle(color)
  }
}
