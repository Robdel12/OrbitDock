//
//  ReadExpandedView.swift
//  OrbitDock
//
//  Code editor experience for file read output.
//  Server sends clean content (cat -n prefixes stripped) + start_line for real line numbers.
//  Features: FileTabHeader, syntax highlighting, real file line numbers, CodeViewport.
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
        let lineCount = content.outputDisplay?
          .components(separatedBy: "\n").count ?? 0
        FileTabHeader(
          path: input,
          language: content.language,
          metric: "\(lineCount) lines"
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
        let startLine = content.startLine ?? 1
        let maxLineNum = startLine + lines.count - 1
        let gutterChars = max(3, "\(maxLineNum)".count)
        let lang = content.language

        CodeViewport(lineCount: lines.count, accentColor: .toolRead) {
          ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
            let lineNum = startLine + index

            HStack(alignment: .top, spacing: 0) {
              // ── Line number ──
              Text("\(lineNum)")
                .font(.system(size: TypeScale.code, design: .monospaced))
                .foregroundStyle(Color.toolRead.opacity(0.4))
                .frame(width: CGFloat(gutterChars) * 7 + Spacing.sm_, alignment: .trailing)
                .padding(.trailing, Spacing.xs)

              // ── Gutter bar (3pt, matches Edit edge bar weight) ──
              Rectangle()
                .fill(Color.textQuaternary.opacity(0.08))
                .frame(width: 3)

              // ── Content ──
              if let lang, !lang.isEmpty, !line.isEmpty {
                let highlighted = SyntaxHighlighter.highlightLine(line, language: lang)
                Text(highlighted)
                  .padding(.leading, Spacing.sm_)
              } else {
                Text(line.isEmpty ? " " : line)
                  .font(.system(size: TypeScale.code, design: .monospaced))
                  .foregroundStyle(Color.textSecondary)
                  .padding(.leading, Spacing.sm_)
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
