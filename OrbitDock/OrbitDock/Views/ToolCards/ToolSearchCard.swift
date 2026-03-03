//
//  ToolSearchCard.swift
//  OrbitDock
//
//  Shows tool discovery/search operations
//

import SwiftUI

struct ToolSearchCard: View {
  let message: TranscriptMessage
  @Binding var isExpanded: Bool

  private var color: Color {
    Color(red: 0.5, green: 0.65, blue: 0.8)
  } // Blue-gray

  private var query: String {
    (message.toolInput?["query"] as? String) ?? ""
  }

  private var output: String {
    message.toolOutput ?? ""
  }

  /// Parse found tools from output
  private var foundTools: [String] {
    let lines = output.components(separatedBy: "\n")
    return lines.filter { line in
      line.contains("mcp__") || line.contains("Tool:") || line.contains("- ")
    }.prefix(10).map { $0.trimmingCharacters(in: .whitespaces) }
  }

  var body: some View {
    ToolCardContainer(color: color, isExpanded: $isExpanded, hasContent: !output.isEmpty) {
      header
    } content: {
      expandedContent
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: Spacing.md) {
      Image(systemName: "puzzlepiece.extension")
        .font(.system(size: TypeScale.subhead, weight: .medium))
        .foregroundStyle(color)

      VStack(alignment: .leading, spacing: Spacing.xxs) {
        HStack(spacing: Spacing.sm) {
          Text("ToolSearch")
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(color)

          if !foundTools.isEmpty {
            Text("\(foundTools.count) found")
              .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
              .foregroundStyle(.secondary)
          }
        }

        Text(query)
          .font(.system(size: TypeScale.meta, design: .monospaced))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer()

      if !message.isInProgress {
        ToolCardDuration(duration: message.formattedDuration)
      }

      if message.isInProgress {
        HStack(spacing: Spacing.sm_) {
          ProgressView()
            .controlSize(.mini)
          Text("Searching...")
            .font(.system(size: TypeScale.meta, weight: .medium))
            .foregroundStyle(color)
        }
      } else if !output.isEmpty {
        ToolCardExpandButton(isExpanded: $isExpanded)
      }
    }
  }

  // MARK: - Expanded Content

  private var expandedContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Query
      VStack(alignment: .leading, spacing: Spacing.sm_) {
        Text("QUERY")
          .font(.system(size: TypeScale.mini, weight: .bold, design: .rounded))
          .foregroundStyle(Color.textQuaternary)
          .tracking(0.5)

        Text(query)
          .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
          .foregroundStyle(.primary)
          .textSelection(.enabled)
      }
      .padding(Spacing.md)

      // Found tools
      if !output.isEmpty {
        VStack(alignment: .leading, spacing: Spacing.sm_) {
          Text("FOUND TOOLS")
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
}
