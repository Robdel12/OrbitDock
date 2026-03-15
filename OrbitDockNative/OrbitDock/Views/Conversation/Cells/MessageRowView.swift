//
//  MessageRowView.swift
//  OrbitDock
//
//  User messages: right-aligned bubble with accent tint.
//  Assistant messages: left-aligned, full-width prose.
//  System messages: centered, muted.
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
      case .user: .accent
      case .assistant: .accent
      case .system: .textQuaternary
      }
    }
  }

  var body: some View {
    switch role {
    case .user:
      userMessage
    case .assistant:
      assistantMessage
    case .system:
      systemMessage
    }
  }

  // MARK: - User Message (right-aligned bubble)

  private var userMessage: some View {
    HStack {
      Spacer(minLength: availableWidth * 0.2)

      VStack(alignment: .trailing, spacing: Spacing.xs) {
        Text(role.label)
          .font(.system(size: TypeScale.chatLabel, weight: .semibold))
          .foregroundStyle(Color.textTertiary)

        if !content.isEmpty {
          MarkdownContentRepresentable(
            content: content, style: .standard,
            availableWidth: min(availableWidth * 0.75, availableWidth - Spacing.xl * 2)
          )
        }
      }
      .padding(.horizontal, Spacing.lg_)
      .padding(.vertical, Spacing.md)
      .background(
        RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
          .fill(Color.accent.opacity(OpacityTier.subtle))
      )
      .overlay(
        RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
          .stroke(Color.accent.opacity(0.08), lineWidth: 1)
      )
    }
    .padding(.horizontal, Spacing.xl)
    .padding(.vertical, Spacing.sm)
  }

  // MARK: - Assistant Message (left-aligned, full prose)

  private var assistantMessage: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text(role.label)
        .font(.system(size: TypeScale.chatLabel, weight: .semibold))
        .foregroundStyle(role.color)

      if !content.isEmpty {
        MarkdownContentRepresentable(
          content: content, style: .standard,
          availableWidth: min(availableWidth, 800)
        )
      }

      if isStreaming {
        streamingIndicator
      }
    }
    .padding(.horizontal, Spacing.xl)
    .padding(.vertical, Spacing.md)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: - System Message (centered, muted)

  private var systemMessage: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      if !content.isEmpty {
        Text(content)
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textQuaternary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.horizontal, Spacing.xl)
    .padding(.vertical, Spacing.xs)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: - Streaming

  private var streamingIndicator: some View {
    HStack(spacing: Spacing.xs) {
      ForEach(0 ..< 3, id: \.self) { i in
        Circle()
          .fill(Color.accent.opacity(0.5))
          .frame(width: 4, height: 4)
      }
    }
    .padding(.top, Spacing.xxs)
  }
}
