//
//  ImageExpandedView.swift
//  OrbitDock
//
//  Inline image display for ViewImage and ImageGeneration tools.
//  Features: format badge, dimensions badge, caption support.
//

import SwiftUI

struct ImageExpandedView: View {
  let content: ServerRowContent
  let toolKind: ServerConversationToolKind
  let imageLoader: ImageLoader?
  let sessionId: String
  let endpointId: UUID?
  private static let remotePreviewMaxWidth: CGFloat = 560

  private var messageImages: [MessageImage] {
    content.images.enumerated().compactMap { index, image in
      image.toMessageImage(index: index, endpointId: endpointId, sessionId: sessionId)
    }
  }

  private var displayPath: String? {
    if toolKind == .viewImage, messageImages.isEmpty {
      return content.inputDisplay
    }
    return content.images.first { $0.inputType == "path" }?.value
  }

  private var promptText: String? {
    guard toolKind == .imageGeneration else { return nil }
    let trimmed = content.inputDisplay?.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed?.isEmpty == false ? trimmed : nil
  }

  private var fileName: String? {
    displayPath?.components(separatedBy: "/").last
  }

  private var formatBadge: String? {
    guard let name = fileName else { return nil }
    let ext = name.components(separatedBy: ".").last?.uppercased()
    switch ext {
      case "PNG", "JPG", "JPEG", "GIF", "SVG", "WEBP", "HEIC", "TIFF":
        return ext
      default:
        return nil
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      if let prompt = promptText {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text("Revised Prompt")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textTertiary)
          Text(prompt)
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.sm))
        }
      }

      if let path = displayPath, !path.isEmpty {
        HStack(spacing: Spacing.sm) {
          Image(systemName: "photo")
            .font(.system(size: IconScale.sm))
            .foregroundStyle(Color.toolRead)
          Text(fileName ?? path)
            .font(.system(size: TypeScale.code, design: .monospaced))
            .foregroundStyle(Color.textSecondary)
          Spacer(minLength: 0)
          if let badge = formatBadge {
            Text(badge)
              .font(.system(size: TypeScale.mini, weight: .semibold))
              .foregroundStyle(Color.textQuaternary)
              .padding(.horizontal, Spacing.sm_)
              .padding(.vertical, Spacing.xxs)
              .background(Color.backgroundSecondary, in: Capsule())
          }
        }
      }

      if let imageLoader, !messageImages.isEmpty {
        MessageImageView(images: messageImages, imageLoader: imageLoader, maxWidth: Self.remotePreviewMaxWidth)
      } else if let path = displayPath {
        imageFallback(path: path)
      }

      if let output = content.outputDisplay, !output.isEmpty,
         !output.contains("\n"), output.count < 200
      {
        Text(output)
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textTertiary)
          .italic()
          .padding(.top, Spacing.xs)
      } else if let output = content.outputDisplay, !output.isEmpty {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text("Result")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textTertiary)
          Text(output)
            .font(.system(size: TypeScale.code, design: .monospaced))
            .foregroundStyle(Color.textSecondary)
            .padding(Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.sm))
        }
      }
    }
  }

  private func imageFallback(path: String) -> some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: "photo.badge.exclamationmark")
        .font(.system(size: IconScale.md))
        .foregroundStyle(Color.textQuaternary)
      Text(path)
        .font(.system(size: TypeScale.code, design: .monospaced))
        .foregroundStyle(Color.textTertiary)
    }
    .padding(Spacing.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.sm))
  }
}
