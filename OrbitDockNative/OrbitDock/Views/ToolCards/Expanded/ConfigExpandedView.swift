//
//  ConfigExpandedView.swift
//  OrbitDock
//
//  Structured key-value display for Config tools.
//

import SwiftUI

struct ConfigExpandedView: View {
  let content: ServerRowContent

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      // Config key header — extract key from JSON input if possible
      configKeyHeader

      if let input = content.inputDisplay, !input.isEmpty {
        if looksLikeJSON(input) {
          JSONTreeView(jsonString: input)
        } else {
          VStack(alignment: .leading, spacing: Spacing.sm_) {
            configFields(input)
          }
          .padding(Spacing.sm)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.sm))
        }
      }

      if let output = content.outputDisplay, !output.isEmpty {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text("Result")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textTertiary)
          if looksLikeJSON(output) {
            JSONTreeView(jsonString: output)
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

  @ViewBuilder
  private func configFields(_ text: String) -> some View {
    // Parse "key = value" or "key: value" patterns
    let lines = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
      fieldRow(line)
    }
  }

  private func fieldRow(_ line: String) -> some View {
    let parts = line.components(separatedBy: ":").map { $0.trimmingCharacters(in: .whitespaces) }
    return HStack(spacing: Spacing.sm) {
      if parts.count >= 2 {
        Text(parts[0])
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.textTertiary)
        Text(parts.dropFirst().joined(separator: ":"))
          .font(.system(size: TypeScale.code, design: .monospaced))
          .foregroundStyle(Color.textSecondary)
      } else {
        Text(line)
          .font(.system(size: TypeScale.code, design: .monospaced))
          .foregroundStyle(Color.textSecondary)
      }
    }
  }

  // MARK: - Config Key Header

  @ViewBuilder
  private var configKeyHeader: some View {
    if let input = content.inputDisplay, !input.isEmpty,
       looksLikeJSON(input),
       let data = input.data(using: .utf8),
       let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let key = dict["key"] as? String {
      HStack(spacing: Spacing.sm) {
        Image(systemName: "gearshape")
          .font(.system(size: IconScale.sm))
          .foregroundStyle(Color.textTertiary)
        Text(key)
          .font(.system(size: TypeScale.code, weight: .semibold, design: .monospaced))
          .foregroundStyle(Color.textSecondary)
      }
    } else {
      HStack(spacing: Spacing.sm) {
        Image(systemName: "gearshape")
          .font(.system(size: IconScale.sm))
          .foregroundStyle(Color.textTertiary)
        Text("Configuration")
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.textTertiary)
      }
    }
  }

  private func looksLikeJSON(_ text: String) -> Bool {
    ToolCardStyle.looksLikeJSON(text)
  }
}
