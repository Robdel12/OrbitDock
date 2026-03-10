//
//  GrepCard.swift
//  OrbitDock
//
//  Search results with file grouping
//

import SwiftUI

struct GrepCard: View {
  let message: TranscriptMessage
  @Binding var isExpanded: Bool

  private var color: Color {
    ToolCardStyle.color(for: message.toolName)
  }

  private var output: String {
    message.toolOutput ?? ""
  }

  private var lines: [String] {
    output.components(separatedBy: "\n").filter { !$0.isEmpty }
  }

  private var matchCount: Int {
    lines.count
  }

  private var pattern: String {
    message.grepPattern ?? ""
  }

  /// Detect if file list mode (no colons) or content mode
  private var isFileListMode: Bool {
    lines.first.map { !$0.contains(":") } ?? true
  }

  /// Group by file if content mode
  private var grouped: [(file: String, matches: [String])] {
    if isFileListMode {
      return lines.map { (file: $0, matches: [] as [String]) }
    } else {
      var fileMatches: [String: [String]] = [:]
      for line in lines {
        let parts = line.split(separator: ":", maxSplits: 2)
        if parts.count >= 2 {
          let file = String(parts[0])
          let content = parts.count > 2 ? String(parts[1]) + ":" + String(parts[2]) : String(parts[1])
          fileMatches[file, default: []].append(content)
        }
      }
      return fileMatches.keys.sorted().map { (file: $0, matches: fileMatches[$0] ?? []) }
    }
  }

  var body: some View {
    ToolCardContainer(color: color, isExpanded: $isExpanded, hasContent: matchCount > 0) {
      header
    } content: {
      expandedContent
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: Spacing.md) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: TypeScale.subhead, weight: .medium))
        .foregroundStyle(color)

      VStack(alignment: .leading, spacing: Spacing.xxs) {
        Text("Grep")
          .font(.system(size: TypeScale.body, weight: .semibold))
          .foregroundStyle(color)

        Text(pattern)
          .font(.system(size: TypeScale.meta, design: .monospaced))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer()

      if !message.isInProgress {
        HStack(spacing: Spacing.md) {
          if isFileListMode {
            Text("\(matchCount) \(matchCount == 1 ? "file" : "files")")
              .font(.system(size: TypeScale.meta, weight: .semibold, design: .monospaced))
              .foregroundStyle(color)
          } else {
            Text("\(matchCount) in \(grouped.count) \(grouped.count == 1 ? "file" : "files")")
              .font(.system(size: TypeScale.meta, weight: .semibold, design: .monospaced))
              .foregroundStyle(color)
          }

          ToolCardDuration(duration: message.formattedDuration)
        }
      }

      if message.isInProgress {
        ProgressView()
          .controlSize(.mini)
      } else if matchCount > 0 {
        ToolCardExpandButton(isExpanded: $isExpanded)
      }
    }
  }

  // MARK: - Expanded Content

  @ViewBuilder
  private var expandedContent: some View {
    let maxFiles = 5
    let displayFiles = Array(grouped.prefix(maxFiles))
    let hasMore = grouped.count > maxFiles

    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(displayFiles.enumerated()), id: \.offset) { _, item in
        VStack(alignment: .leading, spacing: 0) {
          // File header
          HStack(spacing: Spacing.sm_) {
            Image(systemName: "doc.text")
              .font(.system(size: TypeScale.micro))
              .foregroundStyle(color)
            Text(item.file.components(separatedBy: "/").suffix(3).joined(separator: "/"))
              .font(.system(size: TypeScale.meta, weight: .medium, design: .monospaced))
              .foregroundStyle(.primary.opacity(0.9))
              .lineLimit(1)
            if !item.matches.isEmpty {
              Text("(\(item.matches.count))")
                .font(.system(size: TypeScale.micro, design: .monospaced))
                .foregroundStyle(Color.textTertiary)
            }
          }
          .padding(.vertical, Spacing.xs)
          .padding(.horizontal, Spacing.md)

          // Match lines
          if !item.matches.isEmpty {
            ForEach(Array(item.matches.prefix(5).enumerated()), id: \.offset) { _, match in
              Text(match)
                .font(.system(size: TypeScale.micro, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.vertical, Spacing.xxs)
                .padding(.leading, 28)
                .padding(.trailing, Spacing.md)
            }

            if item.matches.count > 5 {
              Text("... +\(item.matches.count - 5) more")
                .font(.system(size: TypeScale.micro))
                .foregroundStyle(Color.textTertiary)
                .padding(.leading, 28)
                .padding(.vertical, Spacing.xxs)
            }
          }
        }
      }

      if hasMore {
        Text("... +\(grouped.count - maxFiles) more files")
          .font(.system(size: TypeScale.micro, weight: .medium))
          .foregroundStyle(Color.textTertiary)
          .padding(.horizontal, Spacing.md)
          .padding(.vertical, Spacing.sm_)
      }
    }
    .padding(.vertical, Spacing.sm_)
  }
}
