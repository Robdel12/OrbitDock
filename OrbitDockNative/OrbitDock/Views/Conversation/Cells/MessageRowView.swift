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
  let availableWidth: CGFloat
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

  private var userMessage: some View {
    let bubbleMax: CGFloat = min(640, availableWidth)
    let bubbleContentWidth = bubbleMax - Spacing.lg_ * 2

    return VStack(alignment: .trailing, spacing: Spacing.xs) {
      Text("You")
        .font(.system(size: TypeScale.chatLabel, weight: .semibold))
        .foregroundStyle(Color.textTertiary)

      if let imageLoader, !images.isEmpty {
        MessageImageView(
          images: images,
          imageLoader: imageLoader,
          maxWidth: bubbleContentWidth
        )
      }

      if !content.isEmpty {
        MarkdownContentRepresentable(
          content: content, style: .standard,
          availableWidth: bubbleContentWidth
        )
      }
    }
    .padding(.horizontal, Spacing.lg_)
    .padding(.vertical, Spacing.md)
    .frame(maxWidth: bubbleMax, alignment: .trailing)
    .background(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .fill(Color.accent.opacity(OpacityTier.subtle))
    )
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .stroke(Color.accent.opacity(0.06), lineWidth: 1)
    )
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
          maxWidth: availableWidth
        )
      }

      if !content.isEmpty {
        MarkdownContentRepresentable(
          content: content, style: .standard,
          availableWidth: availableWidth
        )
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
