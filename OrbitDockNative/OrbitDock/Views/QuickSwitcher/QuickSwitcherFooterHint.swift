import SwiftUI

struct QuickSwitcherFooterHint: View {
  let isQuickLaunchMode: Bool

  var body: some View {
    HStack(spacing: 0) {
      hintItem(keys: "↑↓", label: "Navigate")
      footerDivider

      if isQuickLaunchMode {
        hintItem(keys: "↵", label: "Launch")
        footerDivider
        hintItem(keys: "⇧↵", label: "Full Sheet")
      } else {
        hintItem(keys: "↵", label: "Select")
        footerDivider
        hintItem(keys: "⌘R", label: "Rename")
      }

      footerDivider
      hintItem(keys: "esc", label: "Close")

      Spacer()
    }
    .padding(.horizontal, Spacing.section)
    .padding(.vertical, Spacing.md)
    .background(Color.backgroundTertiary.opacity(0.3))
  }

  private var footerDivider: some View {
    Rectangle()
      .fill(Color.panelBorder)
      .frame(width: 1, height: Spacing.lg_)
      .padding(.horizontal, Spacing.md)
  }

  private func hintItem(keys: String, label: String) -> some View {
    HStack(spacing: Spacing.sm_) {
      Text(keys)
        .font(.system(size: TypeScale.meta, weight: .medium, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, Spacing.sm_)
        .padding(.vertical, Spacing.gap)
        .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))

      Text(label)
        .font(.system(size: TypeScale.meta))
        .foregroundStyle(Color.textTertiary)
    }
  }
}
