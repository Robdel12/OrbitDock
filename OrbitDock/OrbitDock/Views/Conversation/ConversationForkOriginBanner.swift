import SwiftUI

struct ConversationForkOriginBanner: View {
  let sourceSessionId: String
  let sourceEndpointId: UUID?
  let sourceName: String?

  private var sourceScopedID: String {
    if let scoped = SessionRef(scopedID: sourceSessionId)?.scopedID {
      return scoped
    }
    guard let sourceEndpointId else {
      return sourceSessionId
    }
    return SessionRef(endpointId: sourceEndpointId, sessionId: sourceSessionId).scopedID
  }

  var body: some View {
    Button {
      NotificationCenter.default.post(
        name: .selectSession,
        object: nil,
        userInfo: ["sessionId": sourceScopedID]
      )
    } label: {
      HStack(spacing: Spacing.sm) {
        Image(systemName: "arrow.triangle.branch")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Color.accent)

        Text("Forked from")
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(.secondary)

        Text(sourceName ?? sourceSessionId.prefix(8).description)
          .font(.system(size: TypeScale.caption, weight: .medium))
          .foregroundStyle(Color.accent)
          .lineLimit(1)

        Image(systemName: "arrow.right")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(Color.accent.opacity(0.6))
      }
      .padding(.horizontal, Spacing.lg_)
      .padding(.vertical, Spacing.md_)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.accent.opacity(0.06))
      .overlay(
        RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
          .strokeBorder(Color.accent.opacity(0.15), lineWidth: 1)
      )
      .clipShape(RoundedRectangle(cornerRadius: Radius.ml, style: .continuous))
    }
    .buttonStyle(.plain)
    .padding(.bottom, Spacing.sm)
  }
}
