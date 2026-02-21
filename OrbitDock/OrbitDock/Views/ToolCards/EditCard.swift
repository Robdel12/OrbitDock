//
//  EditCard.swift
//  OrbitDock
//
//  Rich diff view for Edit/Write operations
//

import SwiftUI

struct EditCard: View {
  let message: TranscriptMessage
  @Binding var isExpanded: Bool
  @Environment(\.openFileInReview) private var openFileInReview

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

  /// Parse addition/deletion counts from unified diff format
  private var unifiedDiffStats: (additions: Int, deletions: Int) {
    guard let diff = message.unifiedDiff else { return (0, 0) }
    var additions = 0
    var deletions = 0
    for line in diff.components(separatedBy: "\n") {
      if line.hasPrefix("+"), !line.hasPrefix("+++") { additions += 1 }
      else if line.hasPrefix("-"), !line.hasPrefix("---") { deletions += 1 }
    }
    return (additions, deletions)
  }

  private var isTruncated: Bool {
    let totalOld = oldLines.isEmpty ? unifiedDiffStats.deletions : oldLines.count
    let totalNew = newLines.isEmpty ? unifiedDiffStats.additions : newLines.count
    return totalOld > 25 || totalNew > 25
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
          HStack(spacing: 6) {
            Text(filename)
              .font(.system(size: 13, weight: .semibold, design: .monospaced))
              .foregroundStyle(.primary)

            // "View in Review" link — only when review canvas is available
            if let openFileInReview {
              Button {
                openFileInReview(path)
              } label: {
                HStack(spacing: 3) {
                  Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .bold))
                  Text("Review")
                    .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(Color.accent)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
              }
              .buttonStyle(.plain)
            }
          }

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

  private var effectiveAdditions: Int {
    newLines.isEmpty ? unifiedDiffStats.additions : newLines.count
  }

  private var effectiveDeletions: Int {
    oldLines.isEmpty ? unifiedDiffStats.deletions : oldLines.count
  }

  private var diffStats: some View {
    HStack(spacing: 12) {
      if effectiveDeletions > 0 {
        Text("−\(effectiveDeletions)")
          .font(.system(size: 11, weight: .semibold, design: .monospaced))
          .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.45))
      }
      if effectiveAdditions > 0 {
        Text("+\(effectiveAdditions)")
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
          _ = Platform.services.revealInFileBrowser(path)
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
    let maxLines = isExpanded || !isTruncated ? 120 : 24

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
      // For Codex file changes, render only changed lines (no heavy full-context diff).
      else if let diff = message.unifiedDiff, !diff.isEmpty {
        ChangedDiffView(
          lines: Self.extractChangedLines(fromUnifiedDiff: diff),
          maxLines: maxLines
        )
      }
      // For Edit tool payloads, render only changed lines.
      else if !oldString.isEmpty || !newString.isEmpty {
        ChangedDiffView(
          lines: Self.extractChangedLines(oldString: oldString, newString: newString),
          maxLines: maxLines
        )
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

  static func extractChangedLines(fromUnifiedDiff diff: String) -> [DiffLine] {
    let parsed = DiffModel.parse(unifiedDiff: diff)
    let changed = parsed.files.flatMap { file in
      file.hunks.flatMap { hunk in
        hunk.lines.filter { $0.type == .added || $0.type == .removed }
      }
    }
    if !changed.isEmpty {
      return changed
    }
    return fallbackChangedLines(fromUnifiedDiff: diff)
  }

  static func extractChangedLines(oldString: String, newString: String) -> [DiffLine] {
    let oldLines = oldString.components(separatedBy: "\n")
    let newLines = newString.components(separatedBy: "\n")
    let difference = newLines.difference(from: oldLines)
    var ordered: [(sort: Int, line: DiffLine)] = []
    ordered.reserveCapacity(difference.count)

    for change in difference {
      switch change {
        case let .remove(offset, element, _):
          ordered.append((
            sort: offset * 2,
            line: DiffLine(
              type: .removed,
              content: element,
              oldLineNum: offset + 1,
              newLineNum: nil,
              prefix: "-"
            )
          ))
        case let .insert(offset, element, _):
          ordered.append((
            sort: (offset * 2) + 1,
            line: DiffLine(
              type: .added,
              content: element,
              oldLineNum: nil,
              newLineNum: offset + 1,
              prefix: "+"
            )
          ))
      }
    }

    return ordered.sorted { $0.sort < $1.sort }.map(\.line)
  }

  // MARK: - Lines With Context (for expanded diff view)

  /// Extract ALL lines from a unified diff including context lines.
  static func extractAllLines(fromUnifiedDiff diff: String) -> [DiffLine] {
    let parsed = DiffModel.parse(unifiedDiff: diff)
    let allLines = parsed.files.flatMap { file in
      file.hunks.flatMap(\.lines)
    }
    if !allLines.isEmpty {
      return allLines
    }
    return fallbackChangedLines(fromUnifiedDiff: diff)
  }

  /// Build diff lines from old/new strings, including 1 line of context around changes.
  static func extractLinesWithContext(oldString: String, newString: String) -> [DiffLine] {
    let oldLines = oldString.components(separatedBy: "\n")
    let newLines = newString.components(separatedBy: "\n")
    let difference = newLines.difference(from: oldLines)
    guard !difference.isEmpty else { return [] }

    var removedOffsets = Set<Int>()
    var insertedOffsets = Set<Int>()
    for change in difference {
      switch change {
        case let .remove(offset, _, _):
          removedOffsets.insert(offset)
        case let .insert(offset, _, _):
          insertedOffsets.insert(offset)
      }
    }

    // Build a set of old line indices that need context (adjacent to a removed line)
    var contextOldIndices = Set<Int>()
    for offset in removedOffsets {
      if offset > 0 { contextOldIndices.insert(offset - 1) }
      if offset + 1 < oldLines.count { contextOldIndices.insert(offset + 1) }
    }
    // Remove lines that are themselves being removed — they're changes, not context
    contextOldIndices.subtract(removedOffsets)

    // Build a set of new line indices that need context (adjacent to an inserted line)
    var contextNewIndices = Set<Int>()
    for offset in insertedOffsets {
      if offset > 0 { contextNewIndices.insert(offset - 1) }
      if offset + 1 < newLines.count { contextNewIndices.insert(offset + 1) }
    }
    contextNewIndices.subtract(insertedOffsets)

    // Build output: interleave context + changes in order
    // Walk through old lines, emitting context or removals; track position in new for insertions
    var result: [(sort: Int, line: DiffLine)] = []

    // Add removals and old-side context
    for (i, line) in oldLines.enumerated() {
      if removedOffsets.contains(i) {
        result.append((
          sort: i * 3,
          line: DiffLine(type: .removed, content: line, oldLineNum: i + 1, newLineNum: nil, prefix: "-")
        ))
      } else if contextOldIndices.contains(i) {
        // Map old index to new index for context line numbering
        let newIdx = i + (newLines.count - oldLines.count)
        let newNum: Int? = (newIdx >= 0 && newIdx < newLines.count) ? newIdx + 1 : nil
        result.append((
          sort: i * 3 - 1,
          line: DiffLine(type: .context, content: line, oldLineNum: i + 1, newLineNum: newNum, prefix: " ")
        ))
      }
    }

    // Add insertions and new-side context
    for (i, line) in newLines.enumerated() {
      if insertedOffsets.contains(i) {
        // Sort insertions just after the corresponding old position
        let sortKey = i * 3 + 1
        result.append((
          sort: sortKey,
          line: DiffLine(type: .added, content: line, oldLineNum: nil, newLineNum: i + 1, prefix: "+")
        ))
      } else if contextNewIndices.contains(i), !contextOldIndices.contains(i) {
        // Only add new-side context if it wasn't already added as old-side context
        // (unchanged lines appear in both old and new)
        let oldIdx = i - (newLines.count - oldLines.count)
        let alreadyAdded = oldIdx >= 0 && oldIdx < oldLines.count && contextOldIndices.contains(oldIdx)
        if !alreadyAdded {
          result.append((
            sort: i * 3 - 1,
            line: DiffLine(type: .context, content: line, oldLineNum: nil, newLineNum: i + 1, prefix: " ")
          ))
        }
      }
    }

    return result.sorted { $0.sort < $1.sort }.map(\.line)
  }

  private static func fallbackChangedLines(fromUnifiedDiff diff: String) -> [DiffLine] {
    var lines: [DiffLine] = []
    lines.reserveCapacity(64)

    for raw in diff.components(separatedBy: "\n") {
      if raw.hasPrefix("+++") || raw.hasPrefix("---") || raw.hasPrefix("@@")
        || raw.hasPrefix("diff --git") || raw.hasPrefix("index ")
      {
        continue
      }
      if raw.hasPrefix("+") {
        lines.append(DiffLine(
          type: .added,
          content: String(raw.dropFirst()),
          oldLineNum: nil,
          newLineNum: nil,
          prefix: "+"
        ))
      } else if raw.hasPrefix("-") {
        lines.append(DiffLine(
          type: .removed,
          content: String(raw.dropFirst()),
          oldLineNum: nil,
          newLineNum: nil,
          prefix: "-"
        ))
      }
    }

    return lines
  }
}

// MARK: - Changed Diff View

struct ChangedDiffView: View {
  let lines: [DiffLine]
  var maxLines: Int = 100

  private let addedBg = Color(red: 0.15, green: 0.32, blue: 0.18).opacity(0.6)
  private let removedBg = Color(red: 0.35, green: 0.14, blue: 0.14).opacity(0.6)
  private let addedAccent = Color(red: 0.4, green: 0.95, blue: 0.5)
  private let removedAccent = Color(red: 1.0, green: 0.5, blue: 0.5)

  var body: some View {
    let displayLines = lines.count > maxLines ? Array(lines.prefix(maxLines)) : lines
    let isTruncated = lines.count > maxLines

    VStack(alignment: .leading, spacing: 0) {
      if displayLines.isEmpty {
        Text("No changed lines")
          .font(.system(size: 12))
          .foregroundStyle(.tertiary)
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
      } else {
        ForEach(Array(displayLines.enumerated()), id: \.offset) { _, line in
          diffLineView(line)
        }
      }

      if isTruncated {
        HStack(spacing: 6) {
          Image(systemName: "ellipsis")
            .font(.system(size: 10, weight: .medium))
          Text("\(lines.count - maxLines) more changed lines")
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

      Text(line.content.isEmpty ? " " : line.content)
        .font(.system(size: 12, design: .monospaced))
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
      case .context: .clear
    }
  }

  private func prefixColor(for type: DiffLineType) -> Color {
    switch type {
      case .added: addedAccent
      case .removed: removedAccent
      case .context: .clear
    }
  }
}

// DiffLine and DiffLineType are defined in DiffModel.swift

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
