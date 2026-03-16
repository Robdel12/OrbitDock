//
//  MCPExpandedView.swift
//  OrbitDock
//
//  Generic MCP tool expanded view with SmartJSONView.
//  Smart input/output rendering with error detection.
//

import SwiftUI

struct MCPExpandedView: View {
  let content: ServerRowContent
  let toolRow: ServerConversationToolRow

  private var serverName: String? {
    // Server name is computed as subtitle by the server for MCP tools
    if let subtitle = toolRow.toolDisplay.subtitle {
      return subtitle
    }
    // Fallback: parse from title (mcp__server__tool format)
    let title = toolRow.title
    if title.hasPrefix("mcp__") {
      let parts = title.dropFirst(5).split(separator: "__", maxSplits: 1)
      if let first = parts.first { return String(first) }
    }
    return nil
  }

  private var toolName: String? {
    // Fallback: parse from title (mcp__server__tool format)
    let title = toolRow.title
    if title.hasPrefix("mcp__") {
      let parts = title.dropFirst(5).split(separator: "__", maxSplits: 1)
      if parts.count > 1 { return String(parts[1]) }
    }
    return nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      // Server + tool identity
      HStack(spacing: Spacing.sm) {
        if let server = serverName {
          ServerBadge(serverName: server)
        }
        if let tool = toolName {
          Text(tool)
            .font(.system(size: TypeScale.code, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.textSecondary)
        }
        Spacer()
      }

      // Input
      if let input = content.inputDisplay, !input.isEmpty {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text("Input")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textTertiary)
          SmartJSONView(jsonString: input)
        }
      }

      // Output
      if let output = content.outputDisplay, !output.isEmpty {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text("Output")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textTertiary)

          // Error detection
          let isError = output.lowercased().hasPrefix("error")
            || (looksLikeJSON(output) && output.contains("\"error\""))

          if isError {
            SmartJSONView(jsonString: output)
              .padding(Spacing.sm)
              .background(
                Color.feedbackNegative.opacity(OpacityTier.tint),
                in: RoundedRectangle(cornerRadius: Radius.sm)
              )
          } else {
            SmartJSONView(jsonString: output)
          }
        }
      }
    }
  }

  private func looksLikeJSON(_ text: String) -> Bool {
    ToolCardStyle.looksLikeJSON(text)
  }
}
