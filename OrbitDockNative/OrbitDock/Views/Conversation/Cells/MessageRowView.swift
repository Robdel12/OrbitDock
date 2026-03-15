//
//  MessageRowView.swift
//  OrbitDock
//
//  SwiftUI view for user, assistant, and system message rows.
//

import SwiftUI

struct MessageRowView: View {
  let role: Role
  let content: String
  let images: [ServerImageInput]?
  let isStreaming: Bool
  let availableWidth: CGFloat

  enum Role: String {
    case user, assistant, system

    var label: String {
      switch self {
      case .user: "You"
      case .assistant: "Assistant"
      case .system: "System"
      }
    }

    var color: Color {
      switch self {
      case .user: .textSecondary
      case .assistant: .accent
      case .system: .textTertiary
      }
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text(role.label)
        .font(.system(size: TypeScale.chatLabel, weight: .semibold))
        .foregroundStyle(role.color)

      if !content.isEmpty {
        MarkdownContentRepresentable(content: content, style: .standard, availableWidth: availableWidth)
      }
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.md)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
