//
//  ToolSearchExpandedView.swift
//  OrbitDock
//
//  Tool search results with query display and tool cards.
//

import SwiftUI

struct ToolSearchExpandedView: View {
  let content: ServerRowContent

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      if let input = content.inputDisplay, !input.isEmpty {
        SearchBarVisual(
          query: input,
          icon: "puzzlepiece.extension",
          tintColor: .toolMcp
        )
      }

      if let output = content.outputDisplay, !output.isEmpty {
        let tools = parseTools(output)
        if !tools.isEmpty {
          VStack(alignment: .leading, spacing: Spacing.sm_) {
            ForEach(Array(tools.enumerated()), id: \.offset) { _, tool in
              toolCard(tool)
            }
          }
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

  // MARK: - Tool Card

  private func toolCard(_ tool: FoundTool) -> some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: ToolCardStyle.icon(for: tool.name))
        .font(.system(size: IconScale.md))
        .foregroundStyle(ToolCardStyle.color(for: tool.name))

      VStack(alignment: .leading, spacing: 0) {
        Text(tool.name)
          .font(.system(size: TypeScale.body, weight: .medium))
          .foregroundStyle(Color.textSecondary)
        if let desc = tool.description {
          Text(desc)
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textTertiary)
            .lineLimit(2)
        }
      }
      Spacer()
    }
    .padding(Spacing.sm)
    .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.sm))
  }

  // MARK: - Parse

  private struct FoundTool {
    let name: String
    let description: String?
  }

  private func parseTools(_ output: String) -> [FoundTool] {
    // Try JSON format
    if let data = output.data(using: .utf8),
       let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
      return array.compactMap { dict in
        guard let name = dict["name"] as? String else { return nil }
        return FoundTool(name: name, description: dict["description"] as? String)
      }
    }

    // Line-based fallback
    let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
    return lines.map { FoundTool(name: $0.trimmingCharacters(in: .whitespaces), description: nil) }
  }
}
