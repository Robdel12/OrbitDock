//
//  EditExpandedView.swift
//  OrbitDock
//
//  Proper diff view with dual line number gutters (old/new),
//  word-level highlighting, syntax highlighting, hunk separators,
//  CodeViewport for large diffs, and DiffChangeStrip.
//

import SwiftUI

// MARK: - Diff Entry Model

/// A single line in a parsed diff with computed line numbers.
private struct DiffEntry: Identifiable {
  let id: Int           // index in the entries array
  let type: DiffType
  let oldLine: Int?     // line number in old file (nil for additions)
  let newLine: Int?     // line number in new file (nil for deletions)
  let content: String   // line content without +/- prefix
  let rawLine: String   // original line with prefix

  enum DiffType {
    case context    // unchanged line (no prefix or space prefix)
    case addition   // + prefix
    case deletion   // - prefix
    case separator  // hunk separator (inserted during parsing)
  }
}

// MARK: - View

struct EditExpandedView: View {
  let content: ServerRowContent
  let toolType: String

  private var isNewFile: Bool {
    guard let diff = content.diffDisplay else { return false }
    let lines = diff.components(separatedBy: "\n").filter { !$0.isEmpty }
    return !lines.contains(where: { $0.hasPrefix("-") })
  }

  /// Parse the raw diff string into structured entries with line numbers.
  private func parseDiff(_ diff: String) -> [DiffEntry] {
    let rawLines = diff.components(separatedBy: "\n")
    var entries: [DiffEntry] = []
    var oldLine = 1
    var newLine = 1
    var prevWasChange = false
    var contextRunLength = 0

    for (index, raw) in rawLines.enumerated() {
      let isChange = raw.hasPrefix("+") || raw.hasPrefix("-")

      // Detect hunk boundaries: if we see a change after 2+ context lines
      // following a previous change, insert a separator
      if isChange && contextRunLength >= 2 && prevWasChange == false && !entries.isEmpty {
        let lastChange = entries.last(where: {
          $0.type == .addition || $0.type == .deletion
        })
        if lastChange != nil {
          entries.append(DiffEntry(
            id: index * 1000, type: .separator,
            oldLine: nil, newLine: nil,
            content: "", rawLine: ""
          ))
        }
      }

      if raw.hasPrefix("-") {
        entries.append(DiffEntry(
          id: index, type: .deletion,
          oldLine: oldLine, newLine: nil,
          content: String(raw.dropFirst()), rawLine: raw
        ))
        oldLine += 1
        contextRunLength = 0
        prevWasChange = true
      } else if raw.hasPrefix("+") {
        entries.append(DiffEntry(
          id: index, type: .addition,
          oldLine: nil, newLine: newLine,
          content: String(raw.dropFirst()), rawLine: raw
        ))
        newLine += 1
        contextRunLength = 0
        prevWasChange = true
      } else {
        // Context line (no prefix or space prefix)
        entries.append(DiffEntry(
          id: index, type: .context,
          oldLine: oldLine, newLine: newLine,
          content: raw, rawLine: raw
        ))
        oldLine += 1
        newLine += 1
        contextRunLength += 1
        if contextRunLength == 1 { prevWasChange = false }
      }
    }

    return entries
  }

  /// Compute word-level diff segments for a deletion line if the next entry is an addition.
  private func wordDiffSegments(entries: [DiffEntry], at index: Int) -> [WordLevelDiff.Segment]? {
    let entry = entries[index]
    guard entry.type == .deletion else { return nil }
    // Look ahead for an adjacent addition
    let nextIdx = index + 1
    guard nextIdx < entries.count, entries[nextIdx].type == .addition else { return nil }
    let result = WordLevelDiff.compute(old: entry.content, new: entries[nextIdx].content)
    return result.old
  }

  /// Width of the single line number gutter (adapts to digit count)
  private func gutterWidth(for maxLine: Int) -> CGFloat {
    CGFloat(max(2, "\(maxLine)".count)) * 7 + Spacing.sm
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      if let input = content.inputDisplay, !input.isEmpty {
        FileTabHeader(
          path: input,
          language: content.language,
          metric: nil,
          badges: isNewFile ? [.init(text: "NEW FILE", color: .feedbackPositive)] : []
        )
      }

      if let diff = content.diffDisplay, !diff.isEmpty {
        diffView(diff)
      }

      if let output = content.outputDisplay, !output.isEmpty {
        codeBlock(label: "Result", text: output)
      }
    }
  }

  // MARK: - Diff View

  @ViewBuilder
  private func diffView(_ diff: String) -> some View {
    let rawLines = diff.components(separatedBy: "\n")
    let adds = rawLines.filter { $0.hasPrefix("+") }.count
    let dels = rawLines.filter { $0.hasPrefix("-") }.count
    let entries = parseDiff(diff)
    let lang = content.language
    let maxLine = max(
      entries.compactMap(\.oldLine).max() ?? 1,
      entries.compactMap(\.newLine).max() ?? 1
    )
    let gutter = gutterWidth(for: maxLine)

    VStack(alignment: .leading, spacing: Spacing.xs) {
      // Header: Changes label + language badge + stats bar
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

      // Diff content with CodeViewport + DiffChangeStrip
      HStack(alignment: .top, spacing: 0) {
        CodeViewport(lineCount: entries.count, maxHeight: 400, accentColor: .toolWrite) {
          ForEach(entries) { entry in
            if entry.type == .separator {
              hunkSeparator(gutter: gutter)
            } else {
              let wordDiff: [WordLevelDiff.Segment]? = {
                guard let idx = entries.firstIndex(where: { $0.id == entry.id }) else { return nil }
                return wordDiffSegments(entries: entries, at: idx)
              }()

              diffLineRow(
                entry: entry,
                wordDiff: wordDiff,
                lang: lang,
                gutter: gutter
              )
            }
          }
        }

        // Change density strip for large diffs
        if rawLines.count > 30 {
          DiffChangeStrip(lines: rawLines, height: 400)
            .padding(.leading, Spacing.xs)
        }
      }
    }
  }

  // MARK: - Diff Line Row

  /// Single line number gutter — shows old line for deletions, new line for additions,
  /// new line for context. No +/- prefix (edge bar already communicates change type).
  private func diffLineRow(
    entry: DiffEntry,
    wordDiff: [WordLevelDiff.Segment]?,
    lang: String?,
    gutter: CGFloat
  ) -> some View {
    HStack(spacing: 0) {
      // ── Line number (single column) ──
      let lineNum = entry.type == .deletion ? entry.oldLine : entry.newLine
      Text(lineNum.map { "\($0)" } ?? "")
        .font(.system(size: TypeScale.code, design: .monospaced))
        .foregroundStyle(lineColor(entry.type).opacity(0.4))
        .frame(width: gutter, alignment: .trailing)
        .padding(.trailing, Spacing.xs)

      // ── Edge bar ──
      Rectangle()
        .fill(edgeColor(entry.type))
        .frame(width: 3)

      // ── Content (no +/- prefix — edge bar is sufficient) ──
      if let segments = wordDiff {
        wordLevelContent(segments: segments, type: entry.type)
          .padding(.horizontal, Spacing.sm_)
      } else if let lang, !lang.isEmpty, !entry.content.isEmpty {
        let highlighted = SyntaxHighlighter.highlightLine(entry.content, language: lang)
        Text(highlighted)
          .padding(.horizontal, Spacing.sm_)
      } else {
        Text(entry.content.isEmpty ? " " : entry.content)
          .font(.system(size: TypeScale.code, design: .monospaced))
          .foregroundStyle(lineColor(entry.type))
          .padding(.horizontal, Spacing.sm_)
      }
    }
    .padding(.vertical, 1)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(lineBg(entry.type))
  }

  // MARK: - Hunk Separator

  private func hunkSeparator(gutter: CGFloat) -> some View {
    HStack(spacing: 0) {
      Color.clear
        .frame(width: gutter + Spacing.xs)

      Rectangle()
        .fill(Color.textQuaternary.opacity(0.08))
        .frame(width: 3)

      Spacer()
      Text("\u{22EF}")  // midline horizontal ellipsis
        .font(.system(size: TypeScale.caption, design: .monospaced))
        .foregroundStyle(Color.textQuaternary.opacity(0.4))
      Spacer()
    }
    .frame(height: Spacing.lg)
    .background(Color.textQuaternary.opacity(0.03))
  }

  // MARK: - Word-Level Diff

  @ViewBuilder
  private func wordLevelContent(segments: [WordLevelDiff.Segment], type: DiffEntry.DiffType) -> some View {
    let highlightColor: Color = type == .deletion ? .diffRemovedHighlight : .diffAddedHighlight
    let textColor = lineColor(type)

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

  // MARK: - Style Helpers

  private func lineColor(_ type: DiffEntry.DiffType) -> Color {
    switch type {
    case .addition: .diffAddedAccent
    case .deletion: .diffRemovedAccent
    case .context, .separator: .textTertiary
    }
  }

  private func lineBg(_ type: DiffEntry.DiffType) -> Color {
    switch type {
    case .addition: .diffAddedBg
    case .deletion: .diffRemovedBg
    case .context, .separator: .clear
    }
  }

  private func edgeColor(_ type: DiffEntry.DiffType) -> Color {
    switch type {
    case .addition: .diffAddedEdge
    case .deletion: .diffRemovedEdge
    case .context, .separator: .clear
    }
  }
}
