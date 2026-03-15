//
//  ReadExpandedView.swift
//  OrbitDock
//
//  Code editor experience for file read output.
//  Features: path breadcrumb, syntax highlighting, line numbers.
//

import SwiftUI

struct ReadExpandedView: View {
  let content: ServerRowContent

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      if let input = content.inputDisplay, !input.isEmpty {
        fileBreadcrumb(input)
      }

      if let output = content.outputDisplay, !output.isEmpty {
        let lines = output.components(separatedBy: "\n")
        let gutterChars = max(3, "\(lines.count)".count)
        let lang = content.language

        VStack(alignment: .leading, spacing: Spacing.xs) {
          HStack {
            Text("Content")
              .font(.system(size: TypeScale.caption, weight: .semibold))
              .foregroundStyle(Color.textTertiary)
            Spacer()
            if let lang, !lang.isEmpty { languageBadge(lang) }
            Text("\(lines.count) lines")
              .font(.system(size: TypeScale.mini, design: .monospaced))
              .foregroundStyle(Color.textQuaternary)
          }

          VStack(alignment: .leading, spacing: 0) {
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
                index % 10 >= 5
                  ? Color.white.opacity(0.008)
                  : Color.clear
              )
            }
          }
          .padding(.vertical, Spacing.xs)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.sm))
        }
      }
    }
  }

  // MARK: - Helpers

  private func fileBreadcrumb(_ path: String) -> some View {
    let segments = path.split(separator: "/")
    return HStack(spacing: Spacing.xxs) {
      Image(systemName: "doc.text.fill")
        .font(.system(size: 8))
        .foregroundStyle(Color.toolRead)

      ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
        if index > 0 {
          Text("/")
            .font(.system(size: TypeScale.caption, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)
        }
        Text(String(segment))
          .font(.system(
            size: TypeScale.caption,
            weight: index == segments.count - 1 ? .semibold : .regular,
            design: .monospaced
          ))
          .foregroundStyle(
            index == segments.count - 1 ? Color.textSecondary : Color.textQuaternary
          )
      }
    }
  }

  private func languageBadge(_ lang: String) -> some View {
    Text(lang)
      .font(.system(size: TypeScale.mini, weight: .semibold))
      .foregroundStyle(Color.textQuaternary)
      .padding(.horizontal, Spacing.sm_)
      .padding(.vertical, Spacing.xxs)
      .background(Color.backgroundSecondary, in: Capsule())
  }
}
