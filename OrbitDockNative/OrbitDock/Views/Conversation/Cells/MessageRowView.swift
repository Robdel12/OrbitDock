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
  let images: [ServerImageInput]?
  let isStreaming: Bool
  let availableWidth: CGFloat

  @State private var fullscreenImageIndex: Int?

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

      imageGrid(maxWidth: bubbleContentWidth)

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

      imageGrid(maxWidth: availableWidth)

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
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.vertical, Spacing.xs)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: - Image Grid

  @ViewBuilder
  private func imageGrid(maxWidth: CGFloat) -> some View {
    let resolved = resolvedImages
    if !resolved.isEmpty {
      let columns = resolved.count == 1
        ? [GridItem(.flexible())]
        : [GridItem(.flexible()), GridItem(.flexible())]

      LazyVGrid(columns: columns, spacing: Spacing.sm) {
        ForEach(Array(resolved.enumerated()), id: \.offset) { index, entry in
          MessageImageThumbnail(image: entry.image)
            .onTapGesture { fullscreenImageIndex = index }
        }
      }
      .frame(maxWidth: maxWidth)
      .sheet(item: $fullscreenImageIndex) { index in
        ImageFullscreen(
          images: resolved.map { toMessageImage($0) },
          currentIndex: index
        )
      }
    }
  }

  private struct ResolvedImage {
    let input: ServerImageInput
    let platformImage: PlatformImage

    var image: PlatformImage { platformImage }
  }

  private var resolvedImages: [ResolvedImage] {
    guard let images, !images.isEmpty else { return [] }
    return images.compactMap { input in
      guard let img = loadPlatformImage(from: input) else { return nil }
      return ResolvedImage(input: input, platformImage: img)
    }
  }

  private func toMessageImage(_ resolved: ResolvedImage) -> MessageImage {
    let input = resolved.input
    let source: MessageImage.Source = switch input.inputType {
    case "path": .filePath(input.value)
    case "url": .dataURI(input.value)
    default: .filePath(input.value)
    }
    return MessageImage(
      source: source,
      mimeType: input.mimeType ?? "image/png",
      byteCount: input.byteCount ?? 0,
      pixelWidth: input.pixelWidth,
      pixelHeight: input.pixelHeight
    )
  }
}

// MARK: - Thumbnail View

private struct MessageImageThumbnail: View {
  let image: PlatformImage

  private let maxHeight: CGFloat = 240

  var body: some View {
    #if os(macOS)
      let img = Image(nsImage: image)
    #else
      let img = Image(uiImage: image)
    #endif

    img
      .resizable()
      .aspectRatio(contentMode: .fit)
      .frame(maxHeight: maxHeight)
      .clipShape(RoundedRectangle(cornerRadius: Radius.ml, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
          .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
      )
      .contentShape(Rectangle())
  }
}

// MARK: - Image Loading

private func loadPlatformImage(from input: ServerImageInput) -> PlatformImage? {
  switch input.inputType {
  case "path":
    #if os(macOS)
      return NSImage(contentsOfFile: input.value)
    #else
      return UIImage(contentsOfFile: input.value)
    #endif
  case "url":
    guard input.value.hasPrefix("data:"),
          let commaIndex = input.value.firstIndex(of: ","),
          let data = Data(base64Encoded: String(input.value[input.value.index(after: commaIndex)...]))
    else { return nil }
    #if os(macOS)
      return NSImage(data: data)
    #else
      return UIImage(data: data)
    #endif
  default:
    return nil
  }
}

extension Int: @retroactive Identifiable {
  public var id: Int { self }
}
