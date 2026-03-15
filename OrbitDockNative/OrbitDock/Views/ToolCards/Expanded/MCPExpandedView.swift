//
//  MCPExpandedView.swift
//  OrbitDock
//
//  Generic MCP tool expanded view with JSONTreeView.
//  Replaces flat JSON dumps with interactive, collapsible tree display.
//

import SwiftUI

struct MCPExpandedView: View {
  let content: ServerRowContent
  let toolRow: ServerConversationToolRow

  private var serverName: String? {
    // Extract server from invocation
    if let dict = toolRow.invocation.value as? [String: Any],
       let server = dict["server"] as? String {
      return server
    }
    // Try to extract from title (mcp__server__tool format)
    let title = toolRow.title
    if title.hasPrefix("mcp__") {
      let parts = title.dropFirst(5).split(separator: "__", maxSplits: 1)
      if let first = parts.first { return String(first) }
    }
    return nil
  }

  private var toolName: String? {
    if let dict = toolRow.invocation.value as? [String: Any],
       let tool = dict["tool"] as? String {
      return tool
    }
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
          JSONTreeView(jsonString: input)
        }
      }

      // Output
      if let output = content.outputDisplay, !output.isEmpty {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text("Output")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textTertiary)
          JSONTreeView(jsonString: output)
        }
      }
    }
  }
}
