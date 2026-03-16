//
//  WebFetchExpandedView.swift
//  OrbitDock
//
//  Browser-inspired view for web fetch tool output.
//  Features: URLBarVisual, content-type-aware rendering (JSON → tree, markdown → body, else monospace).
//

import SwiftUI

struct WebFetchExpandedView: View {
  let content: ServerRowContent

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      if let input = content.inputDisplay, !input.isEmpty {
        URLBarVisual(urlString: input)
      }

      if let output = content.outputDisplay, !output.isEmpty {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          // Response label + size metadata
          HStack(spacing: Spacing.sm) {
            Text("Response")
              .font(.system(size: TypeScale.caption, weight: .semibold))
              .foregroundStyle(Color.textTertiary)

            let sizeKB = output.utf8.count / 1024
            if sizeKB > 0 {
              Text("~\(sizeKB) KB")
                .font(.system(size: TypeScale.mini, design: .monospaced))
                .foregroundStyle(Color.textQuaternary)
            }
          }

          // Content-type-aware rendering
          if looksLikeJSON(output) {
            JSONTreeView(jsonString: output)
          } else if looksLikeMarkdown(output) {
            Text(output)
              .font(.system(size: TypeScale.body))
              .foregroundStyle(Color.textSecondary)
              .padding(Spacing.sm)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.sm))
          } else {
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
  }

  private func looksLikeJSON(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return (trimmed.hasPrefix("{") && trimmed.hasSuffix("}"))
        || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]"))
  }

  private func looksLikeMarkdown(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let indicators = ["# ", "## ", "### ", "**", "- ", "* ", "1. ", "`"]
    let matchCount = indicators.filter { trimmed.contains($0) }.count
    return matchCount >= 2
  }
}
