//
//  ImageExpandedView.swift
//  OrbitDock
//
//  Inline image display for ViewImage and ImageGeneration tools.
//

import SwiftUI

struct ImageExpandedView: View {
  let content: ServerRowContent

  private var filePath: String? { content.inputDisplay }

  private var fileName: String? {
    filePath?.components(separatedBy: "/").last
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
      // File path breadcrumb
      if let path = filePath, !path.isEmpty {
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

      // Inline image
      if let path = filePath {
        inlineImage(path: path)
      }

      if let output = content.outputDisplay, !output.isEmpty {
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

  @ViewBuilder
  private func inlineImage(path: String) -> some View {
    #if os(macOS)
    if let image = NSImage(contentsOfFile: path) {
      Image(nsImage: image)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(maxHeight: 300)
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
    } else {
      imageFallback(path: path)
    }
    #else
    if let image = UIImage(contentsOfFile: path) {
      Image(uiImage: image)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(maxHeight: 300)
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
    } else {
      imageFallback(path: path)
    }
    #endif
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
