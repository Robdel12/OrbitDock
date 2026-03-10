//
//  GlobCard.swift
//  OrbitDock
//
//  File tree view for glob results
//

import SwiftUI

struct GlobCard: View {
  let message: TranscriptMessage
  @Binding var isExpanded: Bool

  private var color: Color {
    ToolCardStyle.color(for: message.toolName)
  }

  private var output: String {
    message.toolOutput ?? ""
  }

  private var files: [String] {
    output.components(separatedBy: "\n").filter { !$0.isEmpty }
  }

  private var fileCount: Int {
    files.count
  }

  private var pattern: String {
    message.globPattern ?? "**/*"
  }

  /// Group files by directory
  private var grouped: [String: [String]] {
    Dictionary(grouping: files) { path -> String in
      let components = path.components(separatedBy: "/")
      if components.count > 1 {
        return components.dropLast().joined(separator: "/")
      }
      return "."
    }
  }

  private var sortedDirs: [String] {
    grouped.keys.sorted()
  }

  var body: some View {
    ToolCardContainer(color: color, isExpanded: $isExpanded, hasContent: !files.isEmpty) {
      header
    } content: {
      expandedContent
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: Spacing.md) {
      Image(systemName: "folder.badge.gearshape")
        .font(.system(size: TypeScale.subhead, weight: .medium))
        .foregroundStyle(color)

      VStack(alignment: .leading, spacing: Spacing.xxs) {
        Text("Glob")
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
          Text("\(fileCount) \(fileCount == 1 ? "file" : "files")")
            .font(.system(size: TypeScale.meta, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)

          ToolCardDuration(duration: message.formattedDuration)
        }
      }

      if message.isInProgress {
        ProgressView()
          .controlSize(.mini)
      } else if fileCount > 0 {
        ToolCardExpandButton(isExpanded: $isExpanded)
      }
    }
  }

  // MARK: - Expanded Content

  @ViewBuilder
  private var expandedContent: some View {
    let maxDirs = isExpanded ? sortedDirs.count : min(5, sortedDirs.count)
    let displayDirs = Array(sortedDirs.prefix(maxDirs))
    let hasMoreDirs = sortedDirs.count > maxDirs

    VStack(alignment: .leading, spacing: 0) {
      ForEach(displayDirs, id: \.self) { dir in
        let dirFiles = grouped[dir] ?? []

        VStack(alignment: .leading, spacing: 0) {
          // Directory header
          HStack(spacing: Spacing.sm_) {
            Image(systemName: "folder.fill")
              .font(.system(size: TypeScale.micro))
              .foregroundStyle(.orange)
            Text(dir == "." ? "(root)" : dir)
              .font(.system(size: TypeScale.meta, weight: .medium, design: .monospaced))
              .foregroundStyle(.primary.opacity(0.8))
            Text("(\(dirFiles.count))")
              .font(.system(size: TypeScale.micro, design: .monospaced))
              .foregroundStyle(Color.textTertiary)
          }
          .padding(.vertical, Spacing.xs)
          .padding(.horizontal, Spacing.md)

          // Files
          ForEach(dirFiles.prefix(10), id: \.self) { file in
            let filename = file.components(separatedBy: "/").last ?? file
            HStack(spacing: Spacing.sm_) {
              Image(systemName: "doc")
                .font(.system(size: TypeScale.mini))
                .foregroundStyle(.secondary)
              Text(filename)
                .font(.system(size: TypeScale.meta, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .padding(.vertical, Spacing.xxs)
            .padding(.leading, 28)
            .padding(.trailing, Spacing.md)
          }

          if dirFiles.count > 10 {
            Text("... +\(dirFiles.count - 10) more")
              .font(.system(size: TypeScale.micro))
              .foregroundStyle(Color.textTertiary)
              .padding(.leading, 28)
              .padding(.vertical, Spacing.xxs)
          }
        }
      }

      if hasMoreDirs {
        Text("... +\(sortedDirs.count - maxDirs) more directories")
          .font(.system(size: TypeScale.micro, weight: .medium))
          .foregroundStyle(Color.textTertiary)
          .padding(.horizontal, Spacing.md)
          .padding(.vertical, Spacing.sm_)
      }
    }
    .padding(.vertical, Spacing.sm_)
  }
}
