import SwiftUI

/// Unified passive footer for sessions the user doesn't own.
/// Single card: takeover action + optional status metadata strip.
struct TakeOverInputBar<StatusContent: View>: View {
  let onTakeOver: () -> Void
  @ViewBuilder let statusContent: () -> StatusContent

  @State private var isHovering = false

  var body: some View {
    VStack(spacing: 0) {
      // Primary: takeover action
      Button(action: onTakeOver) {
        HStack(spacing: Spacing.sm) {
          Circle()
            .fill(Color.accent.opacity(isHovering ? 0.6 : 0.3))
            .frame(width: 7, height: 7)

          Text("Take over to send messages")
            .font(.system(size: TypeScale.body))
            .foregroundStyle(Color.textTertiary)

          Spacer()

          HStack(spacing: Spacing.xs) {
            Text("Take Over")
              .font(.system(size: TypeScale.code, weight: .semibold))
            Image(systemName: "arrow.right")
              .font(.system(size: TypeScale.micro, weight: .bold))
          }
          .foregroundStyle(Color.accent)
          .padding(.horizontal, Spacing.md)
          .padding(.vertical, Spacing.xs)
          .background(
            Color.accent.opacity(isHovering ? OpacityTier.light : OpacityTier.subtle),
            in: Capsule()
          )
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.md_)
      }
      .buttonStyle(.plain)

      // Secondary: status metadata (if provided)
      statusContent()
    }
    .background(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .fill(Color.backgroundTertiary)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .strokeBorder(
          isHovering ? Color.accent.opacity(0.3) : Color.accent.opacity(0.12),
          lineWidth: 1
        )
    )
    .onHover { hovering in
      withAnimation(Motion.hover) {
        isHovering = hovering
      }
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.top, Spacing.md)
    .padding(.bottom, Spacing.xs)
  }
}

extension TakeOverInputBar where StatusContent == EmptyView {
  init(onTakeOver: @escaping () -> Void) {
    self.onTakeOver = onTakeOver
    self.statusContent = { EmptyView() }
  }
}

#Preview {
  VStack {
    Spacer()
    TakeOverInputBar(onTakeOver: {})
  }
  .frame(width: 600, height: 200)
  .background(Color.backgroundSecondary)
}
