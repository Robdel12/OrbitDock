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
  let memoryCitation: ServerMemoryCitation?
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
        MarkdownContentView(content: content, style: .standard, isStreaming: isStreaming)
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
        MarkdownContentView(content: content, style: .standard, isStreaming: isStreaming)
      }

      if let memoryCitation, !memoryCitation.entries.isEmpty {
        MessageMemoryCitationView(citation: memoryCitation)
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

private struct MessageMemoryCitationView: View {
  let citation: ServerMemoryCitation

  private var rolloutSummary: String? {
    guard !citation.rolloutIds.isEmpty else { return nil }
    return citation.rolloutIds.joined(separator: ", ")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack(spacing: Spacing.xs) {
        Image(systemName: "brain.head.profile")
          .font(.system(size: TypeScale.micro, weight: .semibold))
          .foregroundStyle(Color.providerCodex)

        Text("Memory Citations")
          .font(.system(size: TypeScale.micro, weight: .semibold))
          .foregroundStyle(Color.textSecondary)
      }

      VStack(alignment: .leading, spacing: Spacing.xs) {
        ForEach(Array(citation.entries.enumerated()), id: \.offset) { _, entry in
          VStack(alignment: .leading, spacing: 2) {
            Text(locationLabel(for: entry))
              .font(.system(size: TypeScale.micro, weight: .semibold, design: .monospaced))
              .foregroundStyle(Color.textPrimary)
              .textSelection(.enabled)

            if let note = trimmed(note: entry.note) {
              Text(note)
                .font(.system(size: TypeScale.micro))
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, Spacing.sm)
          .padding(.vertical, Spacing.xs)
          .background(
            Color.backgroundPrimary.opacity(0.9),
            in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
          )
        }
      }

      if let rolloutSummary {
        Text("Rollouts: \(rolloutSummary)")
          .font(.system(size: TypeScale.mini, weight: .medium))
          .foregroundStyle(Color.textQuaternary)
          .textSelection(.enabled)
      }
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.sm)
    .background(Color.backgroundTertiary.opacity(OpacityTier.medium), in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .stroke(Color.providerCodex.opacity(OpacityTier.light), lineWidth: 1)
    )
  }

  private func locationLabel(for entry: ServerMemoryCitationEntry) -> String {
    if let lineEnd = entry.lineEnd {
      return "\(entry.path):\(entry.lineStart)-\(lineEnd)"
    }
    return "\(entry.path):\(entry.lineStart)"
  }

  private func trimmed(note: String?) -> String? {
    guard let note else { return nil }
    let value = note.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
}
