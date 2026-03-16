//
//  GenericExpandedView.swift
//  OrbitDock
//
//  Fallback expanded view for unrecognized tool types.
//  Auto-detects content format: JSON → tree view, otherwise monospace.
//

import SwiftUI

struct GenericExpandedView: View {
  let content: ServerRowContent

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      if let input = content.inputDisplay, !input.isEmpty {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text("Input")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textTertiary)
          smartContent(input, language: nil)
        }
      }

      if let diff = content.diffDisplay, !diff.isEmpty {
        EditExpandedView(content: content, toolType: "edit")
      }

      if let output = content.outputDisplay, !output.isEmpty {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text("Output")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textTertiary)
          smartContent(output, language: content.language)
        }
      }
    }
  }

  @ViewBuilder
  private func smartContent(_ text: String, language: String?) -> some View {
    if looksLikeJSON(text) {
      SmartJSONView(jsonString: text)
    } else {
      Text(text)
        .font(.system(size: TypeScale.code, design: .monospaced))
        .foregroundStyle(Color.textSecondary)
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.sm))
    }
  }

  private func looksLikeJSON(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return (trimmed.hasPrefix("{") && trimmed.hasSuffix("}"))
        || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]"))
  }
}
