import SwiftUI

struct QuickSwitcherCommandRow: View {
  let command: QuickSwitcherCommand
  let isCompactLayout: Bool
  let isSelected: Bool
  let isHovered: Bool
  let onHoverChanged: (Bool) -> Void
  let onRun: () -> Void

  private var iconSize: CGFloat {
    isCompactLayout ? 28 : 32
  }

  var body: some View {
    Button(action: onRun) {
      HStack(spacing: isCompactLayout ? Spacing.md_ : Spacing.lg_) {
        ZStack {
          RoundedRectangle(cornerRadius: isCompactLayout ? 7 : 8, style: .continuous)
            .fill(Color.accent.opacity(0.1))
            .frame(width: iconSize, height: iconSize)

          Image(systemName: command.icon)
            .font(.system(size: isCompactLayout ? TypeScale.body : TypeScale.subhead, weight: .medium))
            .foregroundStyle(Color.accent.opacity(0.8))
        }

        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text(command.name)
            .font(.system(size: isCompactLayout ? TypeScale.title : TypeScale.subhead, weight: .medium))
            .foregroundStyle(.primary)

          if command.requiresSession {
            Text("Applies to selected session")
              .font(.system(size: isCompactLayout ? TypeScale.caption : TypeScale.meta))
              .foregroundStyle(Color.textTertiary)
          }
        }

        Spacer()

        if !isCompactLayout, let shortcut = command.shortcut {
          Text(shortcut)
            .font(.system(size: TypeScale.meta, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: Radius.sm_, style: .continuous))
        }
      }
      .padding(.horizontal, isCompactLayout ? Spacing.md : Spacing.lg)
      .padding(.vertical, isCompactLayout ? Spacing.md_ : Spacing.md)
      .background(
        QuickSwitcherRowBackground(
          isSelected: isSelected,
          isHovered: isHovered
        )
      )
      .padding(.horizontal, isCompactLayout ? Spacing.xs : Spacing.sm)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovered in
      guard !isCompactLayout else { return }
      onHoverChanged(hovered)
    }
  }
}
