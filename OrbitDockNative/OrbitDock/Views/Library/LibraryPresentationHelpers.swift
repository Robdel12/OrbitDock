import SwiftUI

enum LibraryValueFormatter {
  static func cost(_ cost: Double) -> String {
    if cost >= 100 { return String(format: "$%.0f", cost) }
    if cost >= 10 { return String(format: "$%.1f", cost) }
    return String(format: "$%.2f", cost)
  }

  static func tokens(_ value: Int) -> String {
    if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
    if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
    return "\(value)"
  }
}

struct LibrarySummaryCard: View {
  let label: String
  let value: String
  let accent: Color
  let secondary: String

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xxs) {
      Text(label.uppercased())
        .font(.system(size: TypeScale.mini, weight: .semibold, design: .rounded))
        .foregroundStyle(Color.textQuaternary)

      HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
        Text(value)
          .font(.system(size: TypeScale.body, weight: .bold, design: .rounded))
          .foregroundStyle(accent)

        Text(secondary)
          .font(.system(size: TypeScale.micro, weight: .semibold))
          .foregroundStyle(Color.textTertiary)
          .lineLimit(1)
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm_)
    .background(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .fill(Color.backgroundPrimary.opacity(0.45))
        .overlay(
          RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .stroke(accent.opacity(0.12), lineWidth: 1)
        )
    )
  }
}

struct LibraryFilterChip: View {
  let title: String
  var count: Int?
  var icon: String?
  var tint: Color = .accent
  var isSelected: Bool

  var body: some View {
    HStack(spacing: Spacing.xs) {
      if let icon {
        Image(systemName: icon)
          .font(.system(size: TypeScale.mini, weight: .bold))
      }

      Text(title)
        .font(.system(size: TypeScale.micro, weight: .semibold))
        .lineLimit(1)

      if let count {
        Text("\(count)")
          .font(.system(size: TypeScale.micro, weight: .bold, design: .rounded))
          .padding(.horizontal, 5)
          .padding(.vertical, 1)
          .background(
            Capsule(style: .continuous)
              .fill((isSelected ? tint : Color.surfaceHover).opacity(isSelected ? 0.22 : 0.55))
          )
      }
    }
    .foregroundStyle(isSelected ? tint : Color.textSecondary)
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .background(
      Capsule(style: .continuous)
        .fill((isSelected ? tint : Color.backgroundPrimary).opacity(isSelected ? 0.16 : 0.32))
        .overlay(
          Capsule(style: .continuous)
            .stroke(
              (isSelected ? tint : Color.surfaceBorder).opacity(isSelected ? 0.30 : OpacityTier.subtle),
              lineWidth: 1
            )
        )
    )
  }
}

struct LibraryInlineStat: View {
  let text: String
  let tint: Color

  var body: some View {
    Text(text)
      .font(.system(size: TypeScale.micro, weight: .semibold))
      .foregroundStyle(tint)
  }
}

struct LibraryCountPill: View {
  let text: String
  let tint: Color

  var body: some View {
    Text(text)
      .font(.system(size: TypeScale.micro, weight: .bold, design: .rounded))
      .foregroundStyle(tint)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(Color.surfaceHover.opacity(0.55), in: Capsule())
  }
}
