import SwiftUI

struct QuickSwitcherDashboardRow: View {
  let isCompactLayout: Bool
  let isSelected: Bool
  let isHovered: Bool
  let onHoverChanged: (Bool) -> Void
  let onSelect: () -> Void

  private var iconSize: CGFloat {
    isCompactLayout ? 28 : 32
  }

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: isCompactLayout ? Spacing.md_ : Spacing.lg_) {
        ZStack {
          RoundedRectangle(cornerRadius: isCompactLayout ? 7 : 8, style: .continuous)
            .fill(Color.accent.opacity(0.15))
            .frame(width: iconSize, height: iconSize)

          Image(systemName: "square.grid.2x2")
            .font(.system(size: isCompactLayout ? TypeScale.body : TypeScale.subhead, weight: .semibold))
            .foregroundStyle(Color.accent)
        }

        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text("Dashboard")
            .font(.system(size: isCompactLayout ? TypeScale.title : TypeScale.subhead, weight: .semibold))
            .foregroundStyle(.primary)

          Text("View all agents overview")
            .font(.system(size: isCompactLayout ? TypeScale.caption : TypeScale.meta))
            .foregroundStyle(Color.textTertiary)
        }

        Spacer()

        if !isCompactLayout {
          Text("⌘0")
            .font(.system(size: TypeScale.meta, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: Radius.sm_, style: .continuous))
        }
      }
      .padding(.horizontal, isCompactLayout ? Spacing.md : Spacing.lg)
      .padding(.vertical, Spacing.md_)
      .background(
        QuickSwitcherRowBackground(
          isSelected: isSelected,
          isHovered: isHovered
        )
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovered in
      guard !isCompactLayout else { return }
      onHoverChanged(hovered)
    }
    .padding(.horizontal, isCompactLayout ? Spacing.xs : Spacing.sm)
  }
}
