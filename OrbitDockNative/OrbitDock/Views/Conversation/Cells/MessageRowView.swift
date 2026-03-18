//
//  MessageRowView.swift
//  OrbitDock
//
//  Renders message content only. Outer layout (alignment, max-width, padding)
//  is handled by TimelineRowContent.
//

import SwiftUI

struct MessageRowView: View {
  let role: Role
  let content: String
  let images: [MessageImage]
  let isStreaming: Bool
  let imageLoader: ImageLoader?

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
        case .user: .accent
        case .assistant: .accent
        case .system: .textQuaternary
      }
    }
  }

  var body: some View {
    switch role {
      case .user: userMessage
      case .assistant: assistantMessage
      case .system: systemMessage
    }
  }

  // MARK: - User (bubble)

  @Environment(\.horizontalSizeClass) private var sizeClass

  private var userMessage: some View {
    let bubbleMax: CGFloat = sizeClass == .compact ? 320 : 640

    return VStack(alignment: .trailing, spacing: Spacing.xs) {
      Text("You")
        .font(.system(size: TypeScale.chatLabel, weight: .semibold))
        .foregroundStyle(Color.textTertiary)

      if let imageLoader, !images.isEmpty {
        MessageImageView(
          images: images,
          imageLoader: imageLoader,
          maxWidth: bubbleMax - Spacing.md * 2
        )
      }

      if !content.isEmpty {
        MarkdownContentView(content: content, style: .standard)
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .frame(maxWidth: bubbleMax, alignment: .trailing)
    .overlay(alignment: .trailing) {
      Rectangle()
        .fill(Color.accent.opacity(0.3))
        .frame(width: EdgeBar.width)
    }
    .padding(.vertical, Spacing.sm)
  }

  // MARK: - Assistant

  private var assistantMessage: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text("Assistant")
        .font(.system(size: TypeScale.chatLabel, weight: .semibold))
        .foregroundStyle(Color.accent)

      if let imageLoader, !images.isEmpty {
        MessageImageView(
          images: images,
          imageLoader: imageLoader,
          maxWidth: .infinity
        )
      }

      if !content.isEmpty {
        MarkdownContentView(content: content, style: .standard)
      }

      if isStreaming {
        HStack(spacing: Spacing.xs) {
          ForEach(0 ..< 3, id: \.self) { _ in
            Circle().fill(Color.accent.opacity(0.5)).frame(width: 4, height: 4)
          }
        }
      }
    }
    .padding(.vertical, Spacing.md)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: - System

  private var systemMessage: some View {
    Group {
      if !content.isEmpty {
        Text(content)
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textQuaternary)
      }
    }
    .padding(.vertical, Spacing.xs)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
