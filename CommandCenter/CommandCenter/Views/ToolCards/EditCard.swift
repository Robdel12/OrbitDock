//
//  EditCard.swift
//  OrbitDock
//
//  Rich diff view for Edit/Write operations
//

import AppKit
import SwiftUI

struct EditCard: View {
  let message: TranscriptMessage
  @Binding var isExpanded: Bool

  private var color: Color {
    ToolCardStyle.color(for: message.toolName)
  }

  private var language: String {
    ToolCardStyle.detectLanguage(from: message.filePath)
  }

  private var oldString: String {
    message.editOldString ?? ""
  }

  private var newString: String {
    message.editNewString ?? ""
  }

  private var writeContent: String? {
    message.writeContent
  }

  private var oldLines: [String] {
    oldString.components(separatedBy: "\n").filter { !$0.isEmpty }
  }

  private var newLines: [String] {
    newString.components(separatedBy: "\n").filter { !$0.isEmpty }
  }

  private var isTruncated: Bool {
    oldLines.count > 25 || newLines.count > 25
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // File header bar
      HStack(spacing: 0) {
        Rectangle()
          .fill(color)
          .frame(width: 4)

        HStack(spacing: 12) {
          fileInfo
          Spacer()
          diffStats
          controls
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
      }
      .background(Color.backgroundTertiary.opacity(0.7))

      // Diff content
      diffContent
    }
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color.backgroundTertiary.opacity(0.3))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(color.opacity(0.25), lineWidth: 1)
    )
  }

  // MARK: - File Info

  @ViewBuilder
  private var fileInfo: some View {
    if let path = message.filePath {
      let filename = path.components(separatedBy: "/").last ?? path

      HStack(spacing: 8) {
        Image(systemName: "doc.text.fill")
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(color)

        VStack(alignment: .leading, spacing: 2) {
          Text(filename)
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundStyle(.primary)

          Text(ToolCardStyle.shortenPath(path))
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
      }
    } else {
      Text(message.toolName ?? "Edit")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(color)
    }
  }

  // MARK: - Diff Stats

  private var diffStats: some View {
    HStack(spacing: 12) {
      if !oldLines.isEmpty {
        Text("−\(oldLines.count)")
          .font(.system(size: 11, weight: .semibold, design: .monospaced))
          .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.45))
      }
      if !newLines.isEmpty {
        Text("+\(newLines.count)")
          .font(.system(size: 11, weight: .semibold, design: .monospaced))
          .foregroundStyle(Color(red: 0.4, green: 0.9, blue: 0.5))
      }
    }
  }

  // MARK: - Controls

  private var controls: some View {
    HStack(spacing: 8) {
      // Expand toggle if truncated
      if isTruncated {
        Button {
          withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            isExpanded.toggle()
          }
        } label: {
          HStack(spacing: 4) {
            Text(isExpanded ? "Collapse" : "Expand")
              .font(.system(size: 10, weight: .medium))
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
              .font(.system(size: 9, weight: .semibold))
          }
          .foregroundStyle(.secondary)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
      }

      // Open in Finder
      if let path = message.filePath {
        Button {
          NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
        } label: {
          Image(systemName: "arrow.up.forward.square")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .help("Open in Finder")
      }

      // Status indicator
      if message.isInProgress {
        HStack(spacing: 6) {
          ProgressView()
            .controlSize(.mini)
          Text("Editing...")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
        }
      } else {
        HStack(spacing: 6) {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 14))
            .foregroundStyle(Color.statusWorking)

          if let duration = message.formattedDuration {
            Text(duration)
              .font(.system(size: 10, weight: .medium, design: .monospaced))
              .foregroundStyle(.tertiary)
          }
        }
      }
    }
  }

  // MARK: - Diff Content

  @ViewBuilder
  private var diffContent: some View {
    let maxLines = isExpanded || !isTruncated ? 200 : 30

    VStack(alignment: .leading, spacing: 0) {
      // For Write tool, show full content as addition
      if let content = writeContent {
        let lines = content.components(separatedBy: "\n")
        let displayLines = lines.count > maxLines
          ? Array(lines.prefix(maxLines))
          : lines
        DiffSection(
          lines: displayLines,
          isAddition: true,
          language: language
        )
      }
      // For Edit tool, show unified diff (old_string/new_string)
      else if !oldString.isEmpty || !newString.isEmpty {
        UnifiedDiffView(
          oldString: oldString,
          newString: newString,
          language: language,
          maxLines: maxLines
        )
      }
      // For Codex file changes, render unified_diff via existing CodexDiffView
      else if let diff = message.unifiedDiff, !diff.isEmpty {
        CodexDiffView(diff: diff)
      }
      // Fallback
      else if let input = message.formattedToolInput {
        Text(input)
          .font(.system(size: 13, design: .monospaced))
          .foregroundStyle(.primary.opacity(0.9))
          .textSelection(.enabled)
          .padding(14)
      } else {
        Text("No content")
          .font(.system(size: 12))
          .foregroundStyle(.tertiary)
          .padding(14)
      }
    }
  }
}

// MARK: - Unified Diff View

struct UnifiedDiffView: View {
  let oldString: String
  let newString: String
  let language: String
  var maxLines: Int = 100

  private let addedBg = Color(red: 0.15, green: 0.32, blue: 0.18).opacity(0.6)
  private let removedBg = Color(red: 0.35, green: 0.14, blue: 0.14).opacity(0.6)
  private let contextBg = Color.clear
  private let addedAccent = Color(red: 0.4, green: 0.95, blue: 0.5)
  private let removedAccent = Color(red: 1.0, green: 0.5, blue: 0.5)

  var body: some View {
    let diffLines = computeUnifiedDiff()
    let displayLines = diffLines.count > maxLines ? Array(diffLines.prefix(maxLines)) : diffLines
    let isTruncated = diffLines.count > maxLines

    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(displayLines.enumerated()), id: \.offset) { _, line in
        diffLineView(line)
      }

      if isTruncated {
        HStack(spacing: 6) {
          Image(systemName: "ellipsis")
            .font(.system(size: 10, weight: .medium))
          Text("\(diffLines.count - maxLines) more lines")
            .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.backgroundTertiary.opacity(0.5))
      }
    }
  }

  private func diffLineView(_ line: DiffLine) -> some View {
    HStack(alignment: .top, spacing: 0) {
      // Old line number
      Text(line.oldLineNum.map { String($0) } ?? "")
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(.white.opacity(0.35))
        .frame(width: 36, alignment: .trailing)
        .padding(.trailing, 4)

      // New line number
      Text(line.newLineNum.map { String($0) } ?? "")
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(.white.opacity(0.35))
        .frame(width: 36, alignment: .trailing)
        .padding(.trailing, 8)

      // Change indicator
      Text(line.prefix)
        .font(.system(size: 13, weight: .bold, design: .monospaced))
        .foregroundStyle(prefixColor(for: line.type))
        .frame(width: 16)

      // Code content
      Text(SyntaxHighlighter.highlightLine(
        line.content.isEmpty ? " " : line.content,
        language: language.isEmpty ? nil : language
      ))
      .font(.system(size: 13, design: .monospaced))
      .opacity(line.type == .context ? 0.7 : 1.0)
      .textSelection(.enabled)
      .lineLimit(nil)
      .fixedSize(horizontal: false, vertical: true)

      Spacer(minLength: 0)
    }
    .padding(.vertical, 3)
    .background(backgroundColor(for: line.type))
  }

  private func backgroundColor(for type: DiffLineType) -> Color {
    switch type {
      case .added: addedBg
      case .removed: removedBg
      case .context: contextBg
    }
  }

  private func prefixColor(for type: DiffLineType) -> Color {
    switch type {
      case .added: addedAccent
      case .removed: removedAccent
      case .context: .clear
    }
  }

  private func computeUnifiedDiff() -> [DiffLine] {
    let oldLines = oldString.components(separatedBy: "\n")
    let newLines = newString.components(separatedBy: "\n")
    return computeLCSDiff(oldLines: oldLines, newLines: newLines)
  }

  private func computeLCSDiff(oldLines: [String], newLines: [String]) -> [DiffLine] {
    let m = oldLines.count
    let n = newLines.count

    var dp = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)
    for i in 1 ... m {
      for j in 1 ... n {
        if oldLines[i - 1] == newLines[j - 1] {
          dp[i][j] = dp[i - 1][j - 1] + 1
        } else {
          dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
        }
      }
    }

    var i = m, j = n
    var tempResult: [DiffLine] = []

    while i > 0 || j > 0 {
      if i > 0, j > 0, oldLines[i - 1] == newLines[j - 1] {
        tempResult.append(DiffLine(
          type: .context,
          content: oldLines[i - 1],
          oldLineNum: i,
          newLineNum: j,
          prefix: " "
        ))
        i -= 1
        j -= 1
      } else if j > 0, i == 0 || dp[i][j - 1] >= dp[i - 1][j] {
        tempResult.append(DiffLine(
          type: .added,
          content: newLines[j - 1],
          oldLineNum: nil,
          newLineNum: j,
          prefix: "+"
        ))
        j -= 1
      } else if i > 0 {
        tempResult.append(DiffLine(
          type: .removed,
          content: oldLines[i - 1],
          oldLineNum: i,
          newLineNum: nil,
          prefix: "−"
        ))
        i -= 1
      }
    }

    return tempResult.reversed()
  }
}

// MARK: - Diff Types

enum DiffLineType {
  case added, removed, context
}

struct DiffLine {
  let type: DiffLineType
  let content: String
  let oldLineNum: Int?
  let newLineNum: Int?
  let prefix: String
}

// MARK: - Diff Section (for Write tool)

struct DiffSection: View {
  let lines: [String]
  let isAddition: Bool
  let language: String
  var showHeader: Bool = true

  private var backgroundColor: Color {
    isAddition
      ? Color(red: 0.15, green: 0.32, blue: 0.18).opacity(0.6)
      : Color(red: 0.35, green: 0.14, blue: 0.14).opacity(0.6)
  }

  private var accentColor: Color {
    isAddition
      ? Color(red: 0.4, green: 0.95, blue: 0.5)
      : Color(red: 1.0, green: 0.5, blue: 0.5)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if showHeader {
        HStack(spacing: 6) {
          Image(systemName: isAddition ? "plus.circle.fill" : "minus.circle.fill")
            .font(.system(size: 10, weight: .semibold))
          Text(isAddition ? "NEW FILE" : "REMOVED")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .tracking(0.5)
          Text("(\(lines.count) lines)")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
          Spacer()
        }
        .foregroundStyle(accentColor)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(backgroundColor.opacity(0.5))
      }

      ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
        HStack(alignment: .top, spacing: 0) {
          Text("\(index + 1)")
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.35))
            .frame(width: 36, alignment: .trailing)
            .padding(.trailing, 8)

          Text(isAddition ? "+" : "−")
            .font(.system(size: 13, weight: .bold, design: .monospaced))
            .foregroundStyle(accentColor)
            .frame(width: 16)

          Text(SyntaxHighlighter.highlightLine(line.isEmpty ? " " : line, language: language.isEmpty ? nil : language))
            .font(.system(size: 13, design: .monospaced))
            .textSelection(.enabled)

          Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .background(backgroundColor)
      }
    }
  }
}
