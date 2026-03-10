import SwiftUI

struct QuickSwitcherEmptyState: View {
  let isCompactLayout: Bool
  let searchText: String

  private var circleSize: CGFloat {
    isCompactLayout ? 44 : 56
  }

  private var iconSize: CGFloat {
    isCompactLayout ? 20 : 24
  }

  var body: some View {
    VStack(spacing: isCompactLayout ? Spacing.md : Spacing.lg) {
      ZStack {
        Circle()
          .fill(Color.backgroundTertiary)
          .frame(width: circleSize, height: circleSize)

        Image(systemName: "magnifyingglass")
          .font(.system(size: iconSize, weight: .medium))
          .foregroundStyle(Color.textQuaternary)
      }

      VStack(spacing: Spacing.xs) {
        Text("No agents found")
          .font(.system(size: isCompactLayout ? TypeScale.title : TypeScale.subhead, weight: .medium))
          .foregroundStyle(Color.textSecondary)

        if !searchText.isEmpty {
          Text("Try a different search term")
            .font(.system(size: isCompactLayout ? TypeScale.body : TypeScale.caption))
            .foregroundStyle(Color.textTertiary)
        }
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, isCompactLayout ? 36 : 48)
  }
}
