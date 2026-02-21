import SwiftUI

struct ConversationLoadingView: View {
  var body: some View {
    VStack(spacing: 16) {
      ProgressView()
        .controlSize(.regular)
      Text("Loading conversation...")
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(Color.textTertiary)
    }
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
