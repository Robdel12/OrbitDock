import SwiftUI

struct ConversationForkOriginBanner: View {
  let sourceSessionId: String
  let sourceName: String?

  var body: some View {
    Button {
      NotificationCenter.default.post(
        name: .selectSession,
        object: nil,
        userInfo: ["sessionId": sourceSessionId]
      )
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "arrow.triangle.branch")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Color.accent)

        Text("Forked from")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)

        Text(sourceName ?? sourceSessionId.prefix(8).description)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(Color.accent)
          .lineLimit(1)

        Image(systemName: "arrow.right")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(Color.accent.opacity(0.6))
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.accent.opacity(0.06))
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(Color.accent.opacity(0.15), lineWidth: 1)
      )
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .buttonStyle(.plain)
    .padding(.bottom, 8)
  }
}
