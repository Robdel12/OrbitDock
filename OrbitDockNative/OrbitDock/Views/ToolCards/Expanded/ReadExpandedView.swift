//
//  ReadExpandedView.swift
//  OrbitDock
//
//  Code editor experience for file read output.
//  Features: FileTabHeader, syntax highlighting, line numbers, CodeViewport for large files.
//

import SwiftUI

struct ReadExpandedView: View {
  let content: ServerRowContent

  /// Best-effort detection of partial content from inputDisplay metadata
  private var isPartialContent: Bool {
    guard let input = content.inputDisplay else { return false }
    let lower = input.lowercased()
    return lower.contains("offset") || lower.contains("limit") || lower.contains("lines ")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      if let input = content.inputDisplay, !input.isEmpty {
        let lines = content.outputDisplay?.components(separatedBy: "\n") ?? []
        FileTabHeader(
          path: input,
          language: content.language,
          metric: "\(lines.count) lines"
        )
      }

      // Partial content indicator
      if isPartialContent {
        HStack(spacing: Spacing.xs) {
          Image(systemName: "info.circle")
            .font(.system(size: TypeScale.mini))
            .foregroundStyle(Color.textQuaternary)
          Text("Showing partial content")
            .font(.system(size: TypeScale.mini))
            .foregroundStyle(Color.textQuaternary)
        }
      }

      if let output = content.outputDisplay, !output.isEmpty {
        let lines = output.components(separatedBy: "\n")
        let gutterChars = max(3, "\(lines.count)".count)
        let lang = content.language

        CodeViewport(lineCount: lines.count, accentColor: .toolRead) {
          ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
            HStack(alignment: .top, spacing: 0) {
              Text("\(index + 1)")
                .font(.system(size: TypeScale.code, design: .monospaced))
                .foregroundStyle(Color.textQuaternary.opacity(0.4))
                .frame(width: CGFloat(gutterChars) * 8 + Spacing.sm, alignment: .trailing)
                .padding(.trailing, Spacing.sm)

              Rectangle()
                .fill(Color.textQuaternary.opacity(0.08))
                .frame(width: 1)

              // Syntax-highlighted line
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
    }
  }
}
