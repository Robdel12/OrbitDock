//
//  GrepExpandedView.swift
//  OrbitDock
//
//  Search results experience for grep tool output.
//  Features: SearchBarVisual, results grouped by file, pattern highlighting.
//

import SwiftUI

struct GrepExpandedView: View {
  let content: ServerRowContent

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      if let input = content.inputDisplay, !input.isEmpty {
        let lines = content.outputDisplay?.components(separatedBy: "\n").filter { !$0.isEmpty } ?? []
        SearchBarVisual(query: input, resultCount: lines.count, tintColor: .toolSearch)
      }

      if let output = content.outputDisplay, !output.isEmpty {
        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        let grouped = groupByFile(lines)
        let pattern = content.inputDisplay ?? ""

        if !grouped.isEmpty {
          Text("\(lines.count) matches in \(grouped.count) files")
            .font(.system(size: TypeScale.mini))
            .foregroundStyle(Color.textQuaternary)
            .padding(.top, -Spacing.sm)
        }

        if grouped.isEmpty {
          // Flat list fallback
          flatResults(lines: lines, pattern: pattern)
        } else {
          // Grouped by file, sorted by match count (most matches first)
          let sortedGroups = grouped.sorted { $0.matches.count > $1.matches.count }
          groupedResults(groups: sortedGroups, pattern: pattern)
        }
      }
    }
  }

  // MARK: - Grouped Results

  @ViewBuilder
  private func groupedResults(groups: [(file: String, matches: [(line: Int?, content: String)])], pattern: String) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
        FileMatchGroup(file: group.file, matches: group.matches, pattern: pattern)
      }
    }
  }

  // MARK: - Flat Results

  @ViewBuilder
  private func flatResults(lines: [String], pattern: String) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
        highlightedLine(line, pattern: pattern)
          .padding(.horizontal, Spacing.sm)
          .padding(.vertical, Spacing.xxs)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(.vertical, Spacing.xs)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.sm))
  }

  // MARK: - Parsing

  private struct FileMatch {
    let file: String
    let matches: [(line: Int?, content: String)]
  }

  private func groupByFile(_ lines: [String]) -> [(file: String, matches: [(line: Int?, content: String)])] {
    var groups: [(file: String, matches: [(line: Int?, content: String)])] = []
    var currentFile = ""
    var currentMatches: [(line: Int?, content: String)] = []

    for line in lines {
      // Parse "file:line:content" format
      let parts = line.split(separator: ":", maxSplits: 2)
      if parts.count >= 3,
         let lineNum = Int(parts[1]) {
        let file = String(parts[0])
        let matchContent = String(parts[2])

        if file != currentFile {
          if !currentFile.isEmpty {
            groups.append((file: currentFile, matches: currentMatches))
          }
          currentFile = file
          currentMatches = []
        }
        currentMatches.append((line: lineNum, content: matchContent))
      } else if parts.count >= 2,
                !parts[0].contains(" ") {
        // file:content format (no line number)
        let file = String(parts[0])
        let matchContent = String(parts.dropFirst().joined(separator: ":"))

        if file != currentFile {
          if !currentFile.isEmpty {
            groups.append((file: currentFile, matches: currentMatches))
          }
          currentFile = file
          currentMatches = []
        }
        currentMatches.append((line: nil, content: matchContent))
      }
    }

    if !currentFile.isEmpty {
      groups.append((file: currentFile, matches: currentMatches))
    }

    return groups
  }

  @ViewBuilder
  private func highlightedLine(_ line: String, pattern: String) -> some View {
    if pattern.isEmpty {
      Text(line)
        .font(.system(size: TypeScale.code, design: .monospaced))
        .foregroundStyle(Color.textSecondary)
    } else {
      let highlighted = highlightPattern(in: line, pattern: pattern)
      Text(highlighted)
    }
  }

  private func highlightPattern(in text: String, pattern: String) -> AttributedString {
    var result = AttributedString(text)
    result.font = .system(size: TypeScale.code, design: .monospaced)
    result.foregroundColor = Color.textSecondary

    // Case-insensitive search for the pattern
    let lowered = text.lowercased()
    let patternLowered = pattern.lowercased()
    var searchStart = lowered.startIndex

    while let range = lowered.range(of: patternLowered, range: searchStart..<lowered.endIndex) {
      if let attrRange = Range(range, in: result) {
        result[attrRange].backgroundColor = Color.toolSearch.opacity(0.2)
        result[attrRange].foregroundColor = Color.toolSearch
      }
      searchStart = range.upperBound
    }

    return result
  }
}

// MARK: - File Match Group

private struct FileMatchGroup: View {
  let file: String
  let matches: [(line: Int?, content: String)]
  let pattern: String

  @State private var isExpanded = true

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button(action: { withAnimation(Motion.snappy) { isExpanded.toggle() } }) {
        HStack(spacing: Spacing.sm_) {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(Color.textQuaternary)

          Image(systemName: "doc.text")
            .font(.system(size: 8))
            .foregroundStyle(Color.toolSearch.opacity(0.5))

          Text(ToolCardStyle.shortenPath(file))
            .font(.system(size: TypeScale.code, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.textSecondary)

          Text("\(matches.count)")
            .font(.system(size: TypeScale.mini, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color.toolSearch)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 1)
            .background(Color.toolSearch.opacity(OpacityTier.subtle), in: Capsule())

          Spacer()
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
      }
      .buttonStyle(.plain)

      if isExpanded {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(matches.enumerated()), id: \.offset) { _, match in
            HStack(alignment: .top, spacing: 0) {
              if let lineNum = match.line {
                Text("\(lineNum)")
                  .font(.system(size: TypeScale.code, design: .monospaced))
                  .foregroundStyle(Color.textQuaternary.opacity(0.4))
                  .frame(width: 32, alignment: .trailing)
                  .padding(.trailing, Spacing.xs)
              }

              highlightedContent(match.content)
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xxs)
          }
        }
        .padding(.vertical, Spacing.xxs)
        .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.sm))
        .padding(.horizontal, Spacing.sm)
      }
    }
  }

  @ViewBuilder
  private func highlightedContent(_ text: String) -> some View {
    if pattern.isEmpty {
      Text(text)
        .font(.system(size: TypeScale.code, design: .monospaced))
        .foregroundStyle(Color.textSecondary)
    } else {
      let highlighted = highlightPattern(in: text, pattern: pattern)
      Text(highlighted)
    }
  }

  private func highlightPattern(in text: String, pattern: String) -> AttributedString {
    var result = AttributedString(text)
    result.font = .system(size: TypeScale.code, design: .monospaced)
    result.foregroundColor = Color.textSecondary

    let lowered = text.lowercased()
    let patternLowered = pattern.lowercased()
    var searchStart = lowered.startIndex

    while let range = lowered.range(of: patternLowered, range: searchStart..<lowered.endIndex) {
      if let attrRange = Range(range, in: result) {
        result[attrRange].backgroundColor = Color.toolSearch.opacity(0.2)
        result[attrRange].foregroundColor = Color.toolSearch
      }
      searchStart = range.upperBound
    }

    return result
  }
}
