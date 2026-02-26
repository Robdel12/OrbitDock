import SwiftUI

struct ConversationLoadingView: View {
  @State private var shimmer = false

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
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
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(widths.enumerated()), id: \.offset) { _, fraction in
        RoundedRectangle(cornerRadius: 4)
          .fill(Color.textQuaternary.opacity(0.25))
          .frame(maxWidth: .infinity)
          .frame(height: 12)
          .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
          .scaleEffect(x: fraction, anchor: alignment == .trailing ? .trailing : .leading)
      }
    }
    .padding(.vertical, 12)
    .padding(.horizontal, 16)
    .background(
      RoundedRectangle(cornerRadius: 10)
        .fill(Color.backgroundSecondary.opacity(0.6))
    )
    .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
    .frame(maxWidth: alignment == .trailing ? 280 : nil)
  }
}

struct ConversationEmptyStateView: View {
  var body: some View {
    VStack(spacing: 20) {
      Image(systemName: "text.bubble")
        .font(.system(size: 36, weight: .light))
        .foregroundStyle(Color.textQuaternary)

      VStack(spacing: 6) {
        Text("No messages yet")
          .font(.system(size: 16, weight: .medium))
          .foregroundStyle(Color.textSecondary)
        Text("Start the conversation in your terminal")
          .font(.system(size: 13))
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
      HStack(spacing: 8) {
        Image(systemName: "arrow.up")
          .font(.system(size: 10, weight: .bold))
        Text("Load \(remainingCount) earlier")
          .font(.system(size: 12, weight: .medium))
      }
      .foregroundStyle(Color.textTertiary)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 14)
    }
    .buttonStyle(.plain)
    .padding(.bottom, 10)
  }
}

struct ConversationMessageCountIndicator: View {
  let displayedCount: Int
  let totalCount: Int

  var body: some View {
    Text("\(displayedCount) of \(totalCount) messages")
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(Color.textQuaternary)
      .frame(maxWidth: .infinity)
      .padding(.bottom, 10)
  }
}
