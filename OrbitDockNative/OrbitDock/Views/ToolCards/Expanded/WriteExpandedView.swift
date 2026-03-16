//
//  WriteExpandedView.swift
//  OrbitDock
//
//  Clean file creation view — shows new file content as readable code,
//  not as a diff with + prefixes. Uses CodeViewport for large files.
//

import SwiftUI

struct WriteExpandedView: View {
  let content: ServerRowContent

  /// Clean content lines with `+` prefixes stripped when sourced from diffDisplay.
  private var contentLines: [String] {
    if let diff = content.diffDisplay, !diff.isEmpty {
      return diff
        .components(separatedBy: "\n")
        .map { $0.hasPrefix("+") ? String($0.dropFirst()) : $0 }
    }
    if let output = content.outputDisplay, !output.isEmpty {
      return output.components(separatedBy: "\n")
    }
    return []
  }

  private var lineCount: Int { contentLines.count }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      FileTabHeader(
        path: content.inputDisplay ?? "",
        language: content.language,
        metric: "\(lineCount) lines",
        icon: "doc.badge.plus",
        iconColor: .feedbackPositive,
        badges: [.init(text: "NEW FILE", color: .feedbackPositive)]
      )

      if !contentLines.isEmpty {
        let lang = content.language
        let gutterChars = max(3, "\(lineCount)".count)

        CodeViewport(lineCount: lineCount, accentColor: .feedbackPositive) {
          ForEach(Array(contentLines.enumerated()), id: \.offset) { index, line in
            HStack(alignment: .top, spacing: 0) {
              Text("\(index + 1)")
                .font(.system(size: TypeScale.code, design: .monospaced))
                .foregroundStyle(Color.textQuaternary.opacity(0.4))
                .frame(width: CGFloat(gutterChars) * 8 + Spacing.sm, alignment: .trailing)
                .padding(.trailing, Spacing.sm)

              Rectangle()
                .fill(Color.textQuaternary.opacity(0.08))
                .frame(width: 1)

              if let lang, !lang.isEmpty, !line.isEmpty {
                let highlighted = SyntaxHighlighter.highlightLine(line, language: lang)
                Text(highlighted)
                  .padding(.leading, Spacing.sm)
              } else {
                Text(line.isEmpty ? " " : line)
                  .font(.system(size: TypeScale.code, design: .monospaced))
                  .foregroundStyle(Color.textSecondary)
                  .padding(.leading, Spacing.sm)
              }
            }
            .padding(.vertical, 1)
            .background(
              (index / 5) % 2 == 1
                ? Color.white.opacity(0.012)
                : Color.clear
            )
          }
        }
      }

      // Stats footer
      HStack(spacing: Spacing.sm) {
        Text("Created")
          .font(.system(size: TypeScale.mini, weight: .semibold))
          .foregroundStyle(Color.feedbackPositive)
        Text("\u{00B7}")
          .foregroundStyle(Color.textQuaternary)
        Text("\(lineCount) lines")
          .font(.system(size: TypeScale.mini, design: .monospaced))
          .foregroundStyle(Color.textQuaternary)
        if let lang = content.language, !lang.isEmpty {
          Text("\u{00B7}")
            .foregroundStyle(Color.textQuaternary)
          Text(lang)
            .font(.system(size: TypeScale.mini, weight: .semibold))
            .foregroundStyle(Color.textQuaternary)
        }
      }
    }
  }
}
