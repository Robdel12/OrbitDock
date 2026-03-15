//
//  ANSIColorParser.swift
//  OrbitDock
//
//  Maps ANSI escape codes in terminal output to theme syntax colors.
//  Strips escape sequences and produces an AttributedString with color spans.
//

import SwiftUI

enum ANSIColorParser {
  /// Parse a string containing ANSI escape codes into a colored AttributedString.
  static func parse(_ raw: String) -> AttributedString {
    let stripped = raw
    var result = AttributedString()
    var currentColor: Color = .textSecondary
    var isBold = false
    var scanner = stripped[stripped.startIndex...]

    while !scanner.isEmpty {
      // Look for ESC character (0x1B)
      guard let escIndex = scanner.firstIndex(of: "\u{1B}") else {
        // No more escape codes — append remaining text
        var chunk = AttributedString(String(scanner))
        chunk.foregroundColor = currentColor
        if isBold {
          chunk.font = .system(size: TypeScale.code, weight: .bold, design: .monospaced)
        } else {
          chunk.font = .system(size: TypeScale.code, design: .monospaced)
        }
        result.append(chunk)
        break
      }

      // Append text before the escape
      if escIndex > scanner.startIndex {
        let text = String(scanner[scanner.startIndex..<escIndex])
        var chunk = AttributedString(text)
        chunk.foregroundColor = currentColor
        if isBold {
          chunk.font = .system(size: TypeScale.code, weight: .bold, design: .monospaced)
        } else {
          chunk.font = .system(size: TypeScale.code, design: .monospaced)
        }
        result.append(chunk)
      }

      // Parse the escape sequence: ESC [ <params> m
      scanner = scanner[escIndex...]
      if let mIndex = scanner.firstIndex(of: "m"),
         scanner.index(after: escIndex) < scanner.endIndex,
         scanner[scanner.index(after: escIndex)] == "[" {

        let paramsStart = scanner.index(escIndex, offsetBy: 2)
        let params = String(scanner[paramsStart..<mIndex])
        let codes = params.split(separator: ";").compactMap { Int($0) }

        for code in codes {
          switch code {
          case 0:
            currentColor = .textSecondary
            isBold = false
          case 1:
            isBold = true
          case 30: currentColor = .textQuaternary   // black
          case 31: currentColor = .feedbackNegative  // red
          case 32: currentColor = .feedbackPositive  // green
          case 33: currentColor = .feedbackCaution   // yellow
          case 34: currentColor = .accent            // blue
          case 35: currentColor = .syntaxKeyword     // magenta
          case 36: currentColor = .toolWeb           // cyan
          case 37: currentColor = .textPrimary       // white
          case 90: currentColor = .textTertiary      // bright black (gray)
          case 91: currentColor = .feedbackNegative  // bright red
          case 92: currentColor = .feedbackPositive  // bright green
          case 93: currentColor = .feedbackCaution   // bright yellow
          case 94: currentColor = .accent            // bright blue
          case 95: currentColor = .syntaxKeyword     // bright magenta
          case 96: currentColor = .toolWeb           // bright cyan
          case 97: currentColor = .textPrimary       // bright white
          default: break
          }
        }

        scanner = scanner[scanner.index(after: mIndex)...]
      } else {
        // Malformed escape — skip the ESC char
        scanner = scanner[scanner.index(after: escIndex)...]
      }
    }

    return result
  }

  /// Strip all ANSI escape codes, returning plain text.
  static func stripANSI(_ raw: String) -> String {
    raw.replacingOccurrences(
      of: #"\x1B\[[0-9;]*m"#,
      with: "",
      options: .regularExpression
    )
  }
}
