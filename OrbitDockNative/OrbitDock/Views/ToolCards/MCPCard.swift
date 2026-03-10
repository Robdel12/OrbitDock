//
//  MCPCard.swift
//  OrbitDock
//
//  Generic card for MCP (Model Context Protocol) tool calls
//

import SwiftUI

struct MCPCard: View {
  let message: TranscriptMessage
  @Binding var isExpanded: Bool

  /// Parse mcp__<server>__<tool> pattern
  private var mcpInfo: (server: String, tool: String)? {
    guard let name = message.toolName,
          name.hasPrefix("mcp__") else { return nil }

    let parts = name.dropFirst(5).split(separator: "__", maxSplits: 1)
    guard parts.count == 2 else { return nil }
    return (server: String(parts[0]), tool: String(parts[1]))
  }

  private var serverName: String {
    mcpInfo?.server ?? "mcp"
  }

  private var toolName: String {
    mcpInfo?.tool ?? message.toolName ?? "tool"
  }

  private var color: Color {
    MCPCard.serverColor(serverName)
  }

  /// Format tool name: snake_case → Title Case
  private var displayToolName: String {
    toolName
      .replacingOccurrences(of: "_", with: " ")
      .split(separator: " ")
      .map(\.capitalized)
      .joined(separator: " ")
  }

  var body: some View {
    ToolCardContainer(
      color: color,
      isExpanded: $isExpanded,
      hasContent: message.toolInput != nil || message.toolOutput != nil
    ) {
      header
    } content: {
      expandedContent
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: Spacing.md) {
      Image(systemName: MCPCard.serverIcon(serverName))
        .font(.system(size: TypeScale.subhead, weight: .medium))
        .foregroundStyle(color)

      VStack(alignment: .leading, spacing: Spacing.xxs) {
        HStack(spacing: Spacing.sm) {
          Text(displayToolName)
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(color)

          // Server badge
          Text(serverName)
            .font(.system(size: TypeScale.mini, weight: .bold))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, Spacing.sm_)
            .padding(.vertical, Spacing.xxs)
            .background(color.opacity(0.8), in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        }

        // Show primary parameter as subtitle
        if let subtitle = primaryParameter {
          Text(subtitle)
            .font(.system(size: TypeScale.meta, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }

      Spacer()

      if !message.isInProgress {
        ToolCardDuration(duration: message.formattedDuration)
      }

      if message.isInProgress {
        HStack(spacing: Spacing.sm_) {
          ProgressView()
            .controlSize(.mini)
          Text("Running...")
            .font(.system(size: TypeScale.meta, weight: .medium))
            .foregroundStyle(color)
        }
      } else if message.toolInput != nil || message.toolOutput != nil {
        ToolCardExpandButton(isExpanded: $isExpanded)
      }
    }
  }

  // MARK: - Primary Parameter

  private var primaryParameter: String? {
    guard let input = message.toolInput else { return nil }

    // Common parameter names to show as subtitle
    let priorityKeys = [
      "query",
      "url",
      "path",
      "owner",
      "repo",
      "issue_number",
      "pr_number",
      "branch",
      "message",
      "title",
      "name",
    ]

    for key in priorityKeys {
      if let value = input[key] {
        let str = String(describing: value)
        if !str.isEmpty, str != "<null>" {
          return str.count > 60 ? String(str.prefix(60)) + "..." : str
        }
      }
    }

    // Fallback to first string parameter
    for (_, value) in input {
      if let str = value as? String, !str.isEmpty {
        return str.count > 60 ? String(str.prefix(60)) + "..." : str
      }
    }

    return nil
  }

  // MARK: - Expanded Content

  private var expandedContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Input parameters
      if let input = message.toolInput, !input.isEmpty {
        VStack(alignment: .leading, spacing: Spacing.sm) {
          Text("INPUT")
            .font(.system(size: TypeScale.mini, weight: .bold, design: .rounded))
            .foregroundStyle(Color.textQuaternary)
            .tracking(0.5)

          VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(Array(input.keys.sorted().prefix(10)), id: \.self) { key in
              if let value = input[key] {
                parameterRow(key: key, value: value)
              }
            }

            if input.count > 10 {
              Text("... +\(input.count - 10) more")
                .font(.system(size: TypeScale.micro))
                .foregroundStyle(Color.textTertiary)
            }
          }
        }
        .padding(Spacing.md)
      }

      // Output
      if let output = message.sanitizedToolOutput, !output.isEmpty {
        VStack(alignment: .leading, spacing: Spacing.sm) {
          Text("OUTPUT")
            .font(.system(size: TypeScale.mini, weight: .bold, design: .rounded))
            .foregroundStyle(Color.textQuaternary)
            .tracking(0.5)

          ScrollView {
            Text(output.count > 1_000 ? String(output.prefix(1_000)) + "\n[...]" : output)
              .font(.system(size: TypeScale.meta, design: .monospaced))
              .foregroundStyle(.primary.opacity(0.8))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxHeight: 150)
        }
        .padding(Spacing.md)
        .background(Color.backgroundTertiary.opacity(0.5))
      }
    }
  }

  private func parameterRow(key: String, value: Any) -> some View {
    HStack(alignment: .top, spacing: Spacing.sm) {
      Text(key)
        .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
        .foregroundStyle(color.opacity(0.8))
        .frame(minWidth: 80, alignment: .trailing)

      let stringValue = formatValue(value)
      Text(stringValue.count > 200 ? String(stringValue.prefix(200)) + "..." : stringValue)
        .font(.system(size: TypeScale.micro, design: .monospaced))
        .foregroundStyle(.primary.opacity(0.8))
        .textSelection(.enabled)
    }
  }

  private func formatValue(_ value: Any) -> String {
    if let str = value as? String {
      str
    } else if let num = value as? NSNumber {
      num.stringValue
    } else if let bool = value as? Bool {
      bool ? "true" : "false"
    } else if let arr = value as? [Any] {
      "[\(arr.count) items]"
    } else if let dict = value as? [String: Any] {
      "{\(dict.count) fields}"
    } else {
      String(describing: value)
    }
  }

  // MARK: - Server Styling

  static func serverColor(_ server: String) -> Color {
    switch server.lowercased() {
      case "github":
        .serverGitHub
      case "linear-server", "linear":
        .serverLinear
      case "chrome-devtools", "chrome":
        .serverChrome
      case "slack":
        .serverSlack
      case "cupertino":
        .serverApple
      default:
        .serverDefault
    }
  }

  static func serverIcon(_ server: String) -> String {
    switch server.lowercased() {
      case "github":
        "chevron.left.forwardslash.chevron.right"
      case "linear-server", "linear":
        "list.bullet.rectangle"
      case "chrome-devtools", "chrome":
        "globe"
      case "slack":
        "bubble.left.and.bubble.right"
      case "cupertino":
        "apple.logo"
      default:
        "puzzlepiece.extension"
    }
  }
}
