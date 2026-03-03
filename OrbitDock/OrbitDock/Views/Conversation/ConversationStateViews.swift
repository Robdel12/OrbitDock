import SwiftUI

struct ConversationLoadingView: View {
  @State private var shimmer = false

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xl) {
      // Simulated user message
      skeletonBubble(alignment: .trailing, widths: [0.55])

      // Simulated assistant response
      skeletonBubble(alignment: .leading, widths: [0.85, 0.7, 0.45])

      // Simulated tool call
      skeletonBubble(alignment: .leading, widths: [0.6, 0.5])
    }
    .padding(.horizontal, 40)
    .frame(maxWidth: 720, maxHeight: .infinity)
    .mask(
      LinearGradient(
        stops: [
          .init(color: .clear, location: 0),
          .init(color: .black, location: 0.15),
          .init(color: .black, location: 0.85),
          .init(color: .clear, location: 1),
        ],
        startPoint: .top,
        endPoint: .bottom
      )
    )
    .overlay {
      // Shimmer sweep
      Rectangle()
        .fill(
          LinearGradient(
            colors: [.clear, Color.accent.opacity(0.04), .clear],
            startPoint: .leading,
            endPoint: .trailing
          )
        )
        .offset(x: shimmer ? 400 : -400)
        .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: false), value: shimmer)
    }
    .onAppear { shimmer = true }
  }

  private func skeletonBubble(alignment: HorizontalAlignment, widths: [CGFloat]) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      ForEach(Array(widths.enumerated()), id: \.offset) { _, fraction in
        RoundedRectangle(cornerRadius: Radius.sm)
          .fill(Color.textQuaternary.opacity(0.25))
          .frame(maxWidth: .infinity)
          .frame(height: 12)
          .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
          .scaleEffect(x: fraction, anchor: alignment == .trailing ? .trailing : .leading)
      }
    }
    .padding(.vertical, Spacing.md)
    .padding(.horizontal, Spacing.lg)
    .background(
      RoundedRectangle(cornerRadius: Radius.lg)
        .fill(Color.backgroundSecondary.opacity(0.6))
    )
    .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
    .frame(maxWidth: alignment == .trailing ? 280 : nil)
  }
}

struct ConversationEmptyStateView: View {
  var body: some View {
    VStack(spacing: Spacing.section) {
      Image(systemName: "text.bubble")
        .font(.system(size: 36, weight: .light))
        .foregroundStyle(Color.textQuaternary)

      VStack(spacing: Spacing.sm_) {
        Text("No messages yet")
          .font(.system(size: TypeScale.large, weight: .medium))
          .foregroundStyle(Color.textSecondary)
        Text("Start the conversation in your terminal")
          .font(.system(size: TypeScale.body))
          .foregroundStyle(Color.textTertiary)
      }
    }
  }
}

struct ConversationLoadMoreButton: View {
  let remainingCount: Int
  let onLoadMore: () -> Void

  var body: some View {
    Button(action: onLoadMore) {
      HStack(spacing: Spacing.sm) {
        Image(systemName: "arrow.up")
          .font(.system(size: 10, weight: .bold))
        Text("Load \(remainingCount) earlier")
          .font(.system(size: TypeScale.caption, weight: .medium))
      }
      .foregroundStyle(Color.textTertiary)
      .frame(maxWidth: .infinity)
      .padding(.vertical, Spacing.lg_)
    }
    .buttonStyle(.plain)
    .padding(.bottom, Spacing.md_)
  }
}

struct ConversationMessageCountIndicator: View {
  let displayedCount: Int
  let totalCount: Int

  var body: some View {
    Text("\(displayedCount) of \(totalCount) messages")
      .font(.system(size: TypeScale.meta, weight: .medium))
      .foregroundStyle(Color.textQuaternary)
      .frame(maxWidth: .infinity)
      .padding(.bottom, Spacing.md_)
  }
}
