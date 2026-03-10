import SwiftUI

/// Conditionally attaches a context menu only on compact (iOS) layouts.
/// On desktop, this is a no-op so hover-based action buttons remain primary.
struct CompactContextMenuModifier<MenuContent: View>: ViewModifier {
  let isCompact: Bool
  @ViewBuilder let menuContent: () -> MenuContent

  func body(content: Content) -> some View {
    if isCompact {
      content.contextMenu { menuContent() }
    } else {
      content
    }
  }
}

struct QuickSwitcherRowBackground: View {
  let isSelected: Bool
  let isHovered: Bool

  var body: some View {
    ZStack(alignment: .leading) {
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .fill(backgroundColor)

      RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
        .fill(Color.accent)
        .frame(width: 3)
        .padding(.leading, Spacing.xs)
        .padding(.vertical, Spacing.sm_)
        .opacity(isSelected ? 1 : 0)
        .scaleEffect(x: 1, y: isSelected ? 1 : 0.5, anchor: .center)
    }
    .animation(Motion.standard, value: isSelected)
    .animation(Motion.hover, value: isHovered)
  }

  private var backgroundColor: Color {
    if isSelected {
      Color.accent.opacity(0.15)
    } else if isHovered {
      Color.surfaceHover.opacity(0.6)
    } else {
      Color.clear
    }
  }
}
