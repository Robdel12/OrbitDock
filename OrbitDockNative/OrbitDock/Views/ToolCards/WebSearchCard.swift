//
//  WebSearchCard.swift
//  OrbitDock
//
//  Web search with query and results
//

import SwiftUI

struct WebSearchCard: View {
  let message: TranscriptMessage
  @Binding var isExpanded: Bool

  private var color: Color {
    Color(red: 0.3, green: 0.75, blue: 0.75)
  } // Teal

  private var query: String {
    let fromInput = (message.toolInput?["query"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if let fromInput, !fromInput.isEmpty {
      return fromInput
    }
    return message.content
  }

  private var output: String {
    message.toolOutput ?? ""
  }

  /// Try to count results from output
  private var resultCount: Int? {
    // Look for common patterns in search results
    let lines = output.components(separatedBy: "\n")
    let resultLines = lines.filter {
      $0.contains("http") || $0.contains("https") || $0.contains("- [")
    }
    return resultLines.isEmpty ? nil : resultLines.count
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
      Image(systemName: "magnifyingglass.circle.fill")
        .font(.system(size: TypeScale.subhead, weight: .medium))
        .foregroundStyle(color)

      VStack(alignment: .leading, spacing: Spacing.xxs) {
        HStack(spacing: Spacing.sm) {
          Text("WebSearch")
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(color)

          if let count = resultCount {
            Text("\(count) results")
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
          .font(.system(size: TypeScale.caption, weight: .medium))
          .foregroundStyle(.primary)
          .textSelection(.enabled)
      }
      .padding(Spacing.md)

      // Results
      if !output.isEmpty {
        VStack(alignment: .leading, spacing: Spacing.sm_) {
          Text("RESULTS")
            .font(.system(size: TypeScale.mini, weight: .bold, design: .rounded))
            .foregroundStyle(Color.textQuaternary)
            .tracking(0.5)

          ScrollView {
            Text(output.count > 2_000 ? String(output.prefix(2_000)) + "\n[...]" : output)
              .font(.system(size: TypeScale.meta, design: .monospaced))
              .foregroundStyle(.primary.opacity(0.8))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxHeight: 250)
        }
        .padding(Spacing.md)
        .background(Color.backgroundTertiary.opacity(0.5))
      }
    }
  }
}
