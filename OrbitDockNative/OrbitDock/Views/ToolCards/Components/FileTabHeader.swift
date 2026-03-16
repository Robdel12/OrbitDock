//
//  FileTabHeader.swift
//  OrbitDock
//
//  IDE-style file identity bar for Read, Edit, Write, Image, NotebookEdit expanded views.
//  Compact single-line header: language-colored icon + path + optional badges.
//

import SwiftUI

struct FileTabHeader: View {
  let path: String
  let language: String?
  let metric: String?
  var icon: String?
  var iconColor: Color?
  var badges: [FileBadge] = []

  struct FileBadge {
    let text: String
    let color: Color
  }

  var body: some View {
    HStack(spacing: Spacing.sm) {
      // Left: file icon + path
      HStack(spacing: Spacing.sm_) {
        Image(systemName: resolvedIcon)
          .font(.system(size: IconScale.sm))
          .foregroundStyle(resolvedIconColor)

        pathView
      }

      Spacer()

      // Right: badges + language capsule + metric
      HStack(spacing: Spacing.sm_) {
        ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in
          Text(badge.text)
            .font(.system(size: TypeScale.mini, weight: .bold))
            .foregroundStyle(badge.color)
            .padding(.horizontal, Spacing.sm_)
            .padding(.vertical, Spacing.xxs)
            .background(badge.color.opacity(OpacityTier.light), in: Capsule())
        }

        if let language, !language.isEmpty {
          Text(language)
            .font(.system(size: TypeScale.mini, weight: .semibold))
            .foregroundStyle(resolvedIconColor)
            .padding(.horizontal, Spacing.sm_)
            .padding(.vertical, Spacing.xxs)
            .background(resolvedIconColor.opacity(OpacityTier.subtle), in: Capsule())
        }

        if let metric, !metric.isEmpty {
          Text(metric)
            .font(.system(size: TypeScale.mini, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)
        }
      }
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.sm_)
    .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.sm))
  }

  // MARK: - Path Rendering

  private var pathView: some View {
    let segments = path.components(separatedBy: "/").filter { !$0.isEmpty }
    // On narrow screens, show only the last 2 path segments to preserve the filename
    let displaySegments: [String] = {
      #if os(iOS)
        if segments.count > 2 {
          return ["…"] + Array(segments.suffix(2))
        }
      #else
        if segments.count > 5 {
          return ["…"] + Array(segments.suffix(3))
        }
      #endif
      return segments
    }()

    return HStack(spacing: 0) {
      ForEach(Array(displaySegments.enumerated()), id: \.offset) { index, segment in
        if index > 0 {
          Text("/")
            .font(.system(size: TypeScale.code, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)
        }
        if index == displaySegments.count - 1 {
          Text(segment)
            .font(.system(size: TypeScale.code, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color.textSecondary)
        } else {
          Text(segment)
            .font(.system(size: TypeScale.code, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)
        }
      }
    }
    .lineLimit(1)
  }

  // MARK: - Icon Resolution

  private var resolvedIcon: String {
    if let icon { return icon }
    return FileLanguageMapping.icon(for: path)
  }

  private var resolvedIconColor: Color {
    if let iconColor { return iconColor }
    return FileLanguageMapping.color(for: path)
  }
}

// MARK: - Shared Language Mapping

/// Centralized file-extension to icon/color mapping.
/// Used by FileTabHeader, FileTypeDistributionBar, and tree views.
enum FileLanguageMapping {

  static func icon(for path: String) -> String {
    let ext = path.components(separatedBy: ".").last?.lowercased() ?? ""
    switch ext {
      case "swift": return "swift"
      case "rs": return "gearshape"
      case "ts", "tsx", "js", "jsx": return "chevron.left.forwardslash.chevron.right"
      case "py": return "chevron.left.forwardslash.chevron.right"
      case "go": return "chevron.left.forwardslash.chevron.right"
      case "json": return "doc.text"
      case "yaml", "yml", "toml": return "doc.text"
      case "md", "markdown": return "doc.richtext"
      case "ipynb": return "rectangle.split.3x1"
      case "png", "jpg", "jpeg", "svg", "gif", "webp": return "photo"
      default: return "doc.text"
    }
  }

  static func color(for path: String) -> Color {
    let ext = path.components(separatedBy: ".").last?.lowercased() ?? ""
    switch ext {
      case "swift": return .langSwift
      case "rs": return .langRust
      case "ts", "tsx": return .langJavaScript
      case "js", "jsx": return .langJavaScript
      case "py": return .langPython
      case "go": return .langGo
      case "json": return .langJSON
      case "md", "markdown": return .toolRead
      case "ipynb": return .toolWrite
      case "png", "jpg", "jpeg", "svg", "gif", "webp": return .toolRead
      case "yaml", "yml": return .textTertiary
      case "toml": return .langRust
      case "html", "htm": return .langHTML
      case "css", "scss", "sass", "less": return .langCSS
      case "rb": return .langRuby
      case "sh", "bash", "zsh": return .langBash
      default: return .textTertiary
    }
  }

  /// Map file extension to a short language label for distribution legends.
  static func extensionLabel(_ ext: String) -> String {
    ".\(ext)"
  }
}
