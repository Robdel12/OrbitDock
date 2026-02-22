import SwiftUI

/// Input-bar-replacement CTA for passive sessions that can be taken over.
/// Mimics the shape and position of a text input field, sitting above
/// the action bar where the composer row would normally be.
struct TakeOverInputBar: View {
  let onTakeOver: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: onTakeOver) {
      HStack(spacing: Spacing.sm) {
        // Orbit dot — echoes the app's identity
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
      .padding(.vertical, 10)
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
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      withAnimation(.easeOut(duration: 0.15)) {
        isHovering = hovering
      }
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.top, Spacing.md)
    .padding(.bottom, Spacing.xs)
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
