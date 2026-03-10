//
//  MarkdownLanguage.swift
//  OrbitDock
//
//  Shared markdown language metadata used by parser + code block renderers.
//

import SwiftUI

enum MarkdownLanguage {
  static func normalize(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    switch trimmed.lowercased() {
      case "js", "jsx":
        return "javascript"
      case "ts", "tsx":
        return "typescript"
      case "sh", "shell", "zsh":
        return "bash"
      case "py":
        return "python"
      case "rb":
        return "ruby"
      case "yml":
        return "yaml"
      case "md":
        return "markdown"
      case "objective-c", "objc":
        return "objectivec"
      default:
        return trimmed.lowercased()
    }
  }

  static func badgeColor(_ raw: String?) -> Color {
    switch normalize(raw) {
      case "swift":
        Color.langSwift
      case "javascript", "typescript":
        Color.langJavaScript
      case "python":
        Color.langPython
      case "ruby":
        Color.langRuby
      case "go":
        Color.langGo
      case "rust":
        Color.langRust
      case "bash":
        Color.langBash
      case "json":
        Color.langJSON
      case "html":
        Color.langHTML
      case "css":
        Color.langCSS
      case "sql":
        Color.langSQL
      default:
        Color.textTertiary
    }
  }
}
