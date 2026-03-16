//
//  ServerBadge.swift
//  OrbitDock
//
//  MCP server identity pill showing icon + server name + color.
//  Used by MCPExpandedView for server identification.
//

import SwiftUI

struct ServerBadge: View {
  let serverName: String

  private var displayName: String {
    // Clean up server names: "claude_ai_Linear" → "Linear"
    let parts = serverName.split(separator: "_")
    if parts.count > 1 {
      return String(parts.last ?? Substring(serverName)).capitalized
    }
    return serverName
      .replacingOccurrences(of: "-server", with: "")
      .replacingOccurrences(of: "-devtools", with: "")
      .capitalized
  }

  private var color: Color {
    ToolCardStyle.mcpServerColor(serverName)
  }

  private var icon: String {
    ToolCardStyle.mcpServerIcon(serverName)
  }

  var body: some View {
    HStack(spacing: Spacing.xs) {
      Image(systemName: icon)
        .font(.system(size: IconScale.xs))
      Text(displayName)
        .font(.system(size: TypeScale.mini, weight: .semibold))
    }
    .foregroundStyle(color)
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.xxs)
    .background(color.opacity(OpacityTier.subtle), in: Capsule())
  }
}
