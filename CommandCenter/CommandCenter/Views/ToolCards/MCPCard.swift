//
//  MCPCard.swift
//  CommandCenter
//
//  Generic card for MCP (Model Context Protocol) tool calls
//

import SwiftUI

struct MCPCard: View {
    let message: TranscriptMessage
    @Binding var isExpanded: Bool

    // Parse mcp__<server>__<tool> pattern
    private var mcpInfo: (server: String, tool: String)? {
        guard let name = message.toolName,
              name.hasPrefix("mcp__") else { return nil }

        let parts = name.dropFirst(5).split(separator: "__", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return (server: String(parts[0]), tool: String(parts[1]))
    }

    private var serverName: String { mcpInfo?.server ?? "mcp" }
    private var toolName: String { mcpInfo?.tool ?? message.toolName ?? "tool" }

    private var color: Color { MCPCard.serverColor(serverName) }

    // Format tool name: snake_case → Title Case
    private var displayToolName: String {
        toolName
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    var body: some View {
        ToolCardContainer(color: color, isExpanded: $isExpanded, hasContent: message.toolInput != nil || message.toolOutput != nil) {
            header
        } content: {
            expandedContent
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: MCPCard.serverIcon(serverName))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(color)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(displayToolName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(color)

                    // Server badge
                    Text(serverName)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(color.opacity(0.8), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }

                // Show primary parameter as subtitle
                if let subtitle = primaryParameter {
                    Text(subtitle)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if !message.isInProgress {
                ToolCardDuration(duration: message.formattedDuration)
            }

            if message.isInProgress {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Running...")
                        .font(.system(size: 11, weight: .medium))
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
        let priorityKeys = ["query", "url", "path", "owner", "repo", "issue_number", "pr_number", "branch", "message", "title", "name"]

        for key in priorityKeys {
            if let value = input[key] {
                let str = String(describing: value)
                if !str.isEmpty && str != "<null>" {
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

    @ViewBuilder
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Input parameters
            if let input = message.toolInput, !input.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("INPUT")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.quaternary)
                        .tracking(0.5)

                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(input.keys.sorted().prefix(10)), id: \.self) { key in
                            if let value = input[key] {
                                parameterRow(key: key, value: value)
                            }
                        }

                        if input.count > 10 {
                            Text("... +\(input.count - 10) more")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(12)
            }

            // Output
            if let output = message.toolOutput, !output.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("OUTPUT")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.quaternary)
                        .tracking(0.5)

                    ScrollView {
                        Text(output.count > 1000 ? String(output.prefix(1000)) + "\n[...]" : output)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.primary.opacity(0.8))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 150)
                }
                .padding(12)
                .background(Color.backgroundTertiary.opacity(0.5))
            }
        }
    }

    @ViewBuilder
    private func parameterRow(key: String, value: Any) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(color.opacity(0.8))
                .frame(minWidth: 80, alignment: .trailing)

            let stringValue = formatValue(value)
            Text(stringValue.count > 200 ? String(stringValue.prefix(200)) + "..." : stringValue)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.8))
                .textSelection(.enabled)
        }
    }

    private func formatValue(_ value: Any) -> String {
        if let str = value as? String {
            return str
        } else if let num = value as? NSNumber {
            return num.stringValue
        } else if let bool = value as? Bool {
            return bool ? "true" : "false"
        } else if let arr = value as? [Any] {
            return "[\(arr.count) items]"
        } else if let dict = value as? [String: Any] {
            return "{\(dict.count) fields}"
        } else {
            return String(describing: value)
        }
    }

    // MARK: - Server Styling

    static func serverColor(_ server: String) -> Color {
        switch server.lowercased() {
        case "github":
            return Color(red: 0.55, green: 0.45, blue: 0.95)  // Purple (GitHub brand-ish)
        case "linear-server", "linear":
            return Color(red: 0.35, green: 0.5, blue: 0.95)   // Blue (Linear brand)
        case "chrome-devtools", "chrome":
            return Color(red: 0.95, green: 0.6, blue: 0.2)    // Orange (Chrome)
        case "slack":
            return Color(red: 0.9, green: 0.35, blue: 0.55)   // Pink (Slack)
        case "cupertino":
            return Color(red: 0.4, green: 0.7, blue: 0.95)    // Light blue (Apple)
        default:
            return Color(red: 0.5, green: 0.65, blue: 0.8)    // Neutral blue-gray
        }
    }

    static func serverIcon(_ server: String) -> String {
        switch server.lowercased() {
        case "github":
            return "chevron.left.forwardslash.chevron.right"
        case "linear-server", "linear":
            return "list.bullet.rectangle"
        case "chrome-devtools", "chrome":
            return "globe"
        case "slack":
            return "bubble.left.and.bubble.right"
        case "cupertino":
            return "apple.logo"
        default:
            return "puzzlepiece.extension"
        }
    }
}
