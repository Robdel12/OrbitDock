//
//  NativeSyntaxHighlighter.swift
//  OrbitDock
//
//  Thin adapter: reuses SyntaxHighlighter's regex patterns to produce
//  NSAttributedString for native code blocks. All code text uses
//  the same monospaced font — only foreground color varies per token.
//

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

import SwiftUI

enum NativeSyntaxHighlighter {
  private static var lineCache: [String: NSAttributedString] = [:]
  #if os(iOS)
    private static let maxCacheSize = 1_500
  #else
    private static let maxCacheSize = 4_000
  #endif

  static let codeFont = PlatformFont.monospacedSystemFont(ofSize: TypeScale.chatCode, weight: .regular)
  static let defaultColor = PlatformColor(Color.syntaxText)

  /// Highlight a single line, returning an NSAttributedString for native text views.
  static func highlightLine(_ line: String, language: String?) -> NSAttributedString {
    guard let lang = language, !lang.isEmpty, !line.isEmpty else {
      return NSAttributedString(
        string: line,
        attributes: [.font: codeFont, .foregroundColor: defaultColor]
      )
    }

    let cacheKey = "\(lang):\(line)"
    if let cached = lineCache[cacheKey] { return cached }

    // Get the SwiftUI highlighted version and extract colors per character range
    let swiftUIResult = SyntaxHighlighter.highlightLine(line, language: language)
    let nsResult = convertToNSAttributedString(swiftUIResult, text: line)

    if lineCache.count >= maxCacheSize {
      lineCache.removeAll(keepingCapacity: true)
    }
    lineCache[cacheKey] = nsResult
    return nsResult
  }

  static func clearCache() {
    lineCache.removeAll(keepingCapacity: true)
  }

  /// Convert SwiftUI AttributedString to NSAttributedString by extracting
  /// foreground colors from each run and applying them to monospaced text.
  private static func convertToNSAttributedString(_ source: AttributedString, text: String) -> NSAttributedString {
    let result = NSMutableAttributedString(
      string: text,
      attributes: [.font: codeFont, .foregroundColor: defaultColor]
    )

    var offset = 0
    for run in source.runs {
      let runText = String(source[run.range].characters)
      let length = runText.utf16.count
      guard length > 0, offset + length <= (text as NSString).length else {
        offset += length
        continue
      }

      if let color = run.foregroundColor {
        result.addAttribute(
          .foregroundColor,
          value: PlatformColor(color),
          range: NSRange(location: offset, length: length)
        )
      }

      offset += length
    }

    return result
  }
}
