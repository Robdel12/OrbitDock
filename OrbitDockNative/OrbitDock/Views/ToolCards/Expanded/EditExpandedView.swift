//
//  EditExpandedView.swift
//  OrbitDock
//
//  World-class diff view for edit/write tool output.
//  Features: DiffStatsBar, word-level highlighting, syntax highlighting in diffs.
//

import SwiftUI

struct EditExpandedView: View {
  let content: ServerRowContent
  let toolType: String // "edit" or "write" — used to detect new file creation

  private var isNewFile: Bool {
    // If there's no diff (all additions) or the tool is a write with no old_string
    guard let diff = content.diffDisplay else { return false }
    let lines = diff.components(separatedBy: "\n").filter { !$0.isEmpty }
    return !lines.contains(where: { $0.hasPrefix("-") })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      if let input = content.inputDisplay, !input.isEmpty {
        pathHeader(input)
      }

      if let diff = content.diffDisplay, !diff.isEmpty {
        diffView(diff)
      }

      if let output = content.outputDisplay, !output.isEmpty {
        codeBlock(label: "Result", text: output)
      }
    }
  }

  // MARK: - Path Header

  private func pathHeader(_ path: String) -> some View {
    HStack(spacing: Spacing.xs) {
      Image(systemName: isNewFile ? "doc.badge.plus" : "pencil")
        .font(.system(size: 8))
        .foregroundStyle(isNewFile ? Color.feedbackPositive : Color.toolWrite)

      if isNewFile {
        Text("NEW FILE")
          .font(.system(size: TypeScale.mini, weight: .bold))
          .foregroundStyle(Color.feedbackPositive)
          .padding(.horizontal, Spacing.xs)
          .padding(.vertical, 1)
          .background(Color.feedbackPositive.opacity(OpacityTier.subtle), in: Capsule())
      }

      Text(path)
        .font(.system(size: TypeScale.caption, design: .monospaced))
        .foregroundStyle(Color.textTertiary)
    }
  }

  // MARK: - Diff View

  @ViewBuilder
  private func diffView(_ diff: String) -> some View {
    let lines = diff.components(separatedBy: "\n")
    let adds = lines.filter { $0.hasPrefix("+") }.count
    let dels = lines.filter { $0.hasPrefix("-") }.count
    let lang = content.language

    VStack(alignment: .leading, spacing: Spacing.xs) {
      HStack {
        Text("Changes")
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.textTertiary)
        Spacer()
        if let lang, !lang.isEmpty {
          Text(lang)
            .font(.system(size: TypeScale.mini, weight: .semibold))
            .foregroundStyle(Color.textQuaternary)
            .padding(.horizontal, Spacing.sm_)
            .padding(.vertical, Spacing.xxs)
            .background(Color.backgroundSecondary, in: Capsule())
        }
        DiffStatsBar(additions: adds, deletions: dels)
      }

      VStack(alignment: .leading, spacing: 0) {
        let indexedLines = Array(lines.enumerated())
        ForEach(indexedLines, id: \.offset) { index, line in
          // Check for word-level diff on adjacent -/+ pairs
          let wordDiff = wordLevelDiffSegments(lines: lines, currentIndex: index, line: line)

          HStack(spacing: 0) {
            // Edge bar
            Rectangle().fill(diffEdgeColor(line)).frame(width: 3)

            // Prefix (+/-/ )
            Text(diffPrefix(line))
              .font(.system(size: TypeScale.code, weight: .medium, design: .monospaced))
              .foregroundStyle(diffLineColor(line))
              .frame(width: 16, alignment: .center)

            // Content with optional word-level + syntax highlighting
            if let segments = wordDiff {
              wordLevelContent(segments: segments, line: line)
                .padding(.trailing, Spacing.sm)
            } else if let lang, !lang.isEmpty, !diffContent(line).isEmpty {
              // Syntax-highlighted diff content
              let highlighted = SyntaxHighlighter.highlightLine(diffContent(line), language: lang)
              Text(highlighted)
                .padding(.trailing, Spacing.sm)
            } else {
              Text(diffContent(line))
                .font(.system(size: TypeScale.code, design: .monospaced))
                .foregroundStyle(diffLineColor(line))
                .padding(.trailing, Spacing.sm)
            }
          }
          .padding(.vertical, 1)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(diffLineBg(line))
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
    }
  }

  // MARK: - Word-Level Diff

  private func wordLevelDiffSegments(lines: [String], currentIndex: Int, line: String) -> [WordLevelDiff.Segment]? {
    guard line.hasPrefix("-") else { return nil }

    // Look ahead for a matching + line
    let nextIndex = currentIndex + 1
    guard nextIndex < lines.count, lines[nextIndex].hasPrefix("+") else { return nil }

    let oldContent = diffContent(line)
    let newContent = diffContent(lines[nextIndex])
    let result = WordLevelDiff.compute(old: oldContent, new: newContent)
    return result.old
  }

  @ViewBuilder
  private func wordLevelContent(segments: [WordLevelDiff.Segment], line: String) -> some View {
    let isRemoval = line.hasPrefix("-")
    let highlightColor: Color = isRemoval ? .diffRemovedHighlight : .diffAddedHighlight
    let textColor = diffLineColor(line)

    HStack(spacing: 0) {
      ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
        Text(segment.text)
          .font(.system(size: TypeScale.code, design: .monospaced))
          .foregroundStyle(textColor)
          .background(segment.isChanged ? highlightColor : Color.clear)
      }
    }
  }

  // MARK: - Code Block

  private func codeBlock(label: String, text: String) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text(label)
        .font(.system(size: TypeScale.caption, weight: .semibold))
        .foregroundStyle(Color.textTertiary)
      Text(text)
        .font(.system(size: TypeScale.code, design: .monospaced))
        .foregroundStyle(Color.textSecondary)
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.sm))
    }
  }

  // MARK: - Diff Helpers

  private func diffPrefix(_ line: String) -> String {
    if line.hasPrefix("+") { return "+" }
    if line.hasPrefix("-") { return "−" }
    return " "
  }

  private func diffContent(_ line: String) -> String {
    if line.hasPrefix("+") || line.hasPrefix("-") { return String(line.dropFirst()) }
    return line
  }

  private func diffLineColor(_ line: String) -> Color {
    if line.hasPrefix("+") { return .diffAddedAccent }
    if line.hasPrefix("-") { return .diffRemovedAccent }
    return .textTertiary
  }

  private func diffLineBg(_ line: String) -> Color {
    if line.hasPrefix("+") { return .diffAddedBg }
    if line.hasPrefix("-") { return .diffRemovedBg }
    return .clear
  }

  private func diffEdgeColor(_ line: String) -> Color {
    if line.hasPrefix("+") { return .diffAddedEdge }
    if line.hasPrefix("-") { return .diffRemovedEdge }
    return .clear
  }
}
