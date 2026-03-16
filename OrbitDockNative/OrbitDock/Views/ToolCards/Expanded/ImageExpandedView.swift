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

  // imageDimensions computed inline in inlineImage to avoid double disk I/O

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

      // Caption support — short, single-line output treated as caption
      if let output = content.outputDisplay, !output.isEmpty,
         !output.contains("\n"), output.count < 200 {
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

  @ViewBuilder
  private func inlineImage(path: String) -> some View {
    #if os(macOS)
    let imageMaxHeight: CGFloat = 400
    if let image = NSImage(contentsOfFile: path) {
      let dims = "\(Int(image.size.width))\u{00D7}\(Int(image.size.height))"
      VStack(alignment: .leading, spacing: Spacing.xs) {
        Text(dims)
          .font(.system(size: TypeScale.mini, weight: .semibold))
          .foregroundStyle(Color.textQuaternary)
          .padding(.horizontal, Spacing.sm_)
          .padding(.vertical, Spacing.xxs)
          .background(Color.backgroundSecondary, in: Capsule())
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(maxHeight: imageMaxHeight)
          .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
      }
    } else {
      imageFallback(path: path)
    }
    #else
    let imageMaxHeight: CGFloat = 280
    if let image = UIImage(contentsOfFile: path) {
      let dims = "\(Int(image.size.width))\u{00D7}\(Int(image.size.height))"
      VStack(alignment: .leading, spacing: Spacing.xs) {
        Text(dims)
          .font(.system(size: TypeScale.mini, weight: .semibold))
          .foregroundStyle(Color.textQuaternary)
          .padding(.horizontal, Spacing.sm_)
          .padding(.vertical, Spacing.xxs)
          .background(Color.backgroundSecondary, in: Capsule())
        Image(uiImage: image)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(maxHeight: imageMaxHeight)
          .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
      }
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
