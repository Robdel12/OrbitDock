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
          Text(inputSectionHeader(input))
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textTertiary)
          smartContent(input, language: nil)
        }
      }

      if let diff = content.diffDisplay, !diff.isEmpty {
        EditExpandedView(content: content, toolType: "edit")
      }

      if let output = content.outputDisplay, !output.isEmpty {
        let hasError = output.lowercased().contains("error")
          || output.lowercased().contains("failed")
          || output.lowercased().contains("not found")

        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text("Result")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textTertiary)

          if output.count < 100, !output.contains("\n") {
            HStack(spacing: Spacing.sm_) {
              Image(systemName: hasError ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: IconScale.sm))
                .foregroundStyle(hasError ? Color.feedbackNegative : Color.feedbackPositive)
              Text(output)
                .font(.system(size: TypeScale.body))
                .foregroundStyle(hasError ? Color.feedbackNegative : Color.textSecondary)
            }
            .padding(Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
              hasError
                ? Color.feedbackNegative.opacity(OpacityTier.tint)
                : Color.backgroundCode,
              in: RoundedRectangle(cornerRadius: Radius.sm)
            )
          } else {
            smartContent(output, language: content.language, hasError: hasError)
          }
        }
      }
    }
  }

  @ViewBuilder
  private func smartContent(_ text: String, language: String?, hasError: Bool = false) -> some View {
    if looksLikeJSON(text) {
      SmartJSONView(jsonString: text)
    } else {
      Text(text)
        .font(.system(size: TypeScale.code, design: .monospaced))
        .foregroundStyle(Color.textSecondary)
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          hasError
            ? Color.feedbackNegative.opacity(OpacityTier.tint)
            : Color.backgroundCode,
          in: RoundedRectangle(cornerRadius: Radius.sm)
        )
    }
  }

  private func inputSectionHeader(_ input: String) -> String {
    if ToolCardStyle.looksLikeJSON(input),
       let data = input.data(using: .utf8),
       let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      if dict["command"] != nil { return "Command" }
      if dict["query"] != nil { return "Query" }
      if let path = dict["file_path"] as? String ?? dict["path"] as? String {
        return path.components(separatedBy: "/").last ?? "File"
      }
      if dict.values.contains(where: { ($0 as? String)?.hasPrefix("http") == true }) {
        return "URL"
      }
    }
    return "Parameters"
  }

  private func looksLikeJSON(_ text: String) -> Bool {
    ToolCardStyle.looksLikeJSON(text)
  }
}
