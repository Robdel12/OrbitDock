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

/// A single line in a structured diff with view-related additions.
private struct DiffEntry: Identifiable {
  let id: Int
  let kind: EntryKind
  let oldLine: Int?
  let newLine: Int?
  let content: String

  enum EntryKind {
    case context
    case addition
    case deletion
    case separator
  }
}

// MARK: - View

struct EditExpandedView: View {
  let content: ServerRowContent
  let toolType: String

  private var isNewFile: Bool {
    guard let diffLines = content.diffDisplay else { return false }
    // Only truly new if ALL lines are additions (no context or deletions)
    return !diffLines.isEmpty && diffLines.allSatisfy { $0.type == .addition }
  }

  /// Convert structured server diff lines into view entries with hunk separators.
  private func buildEntries(from diffLines: [ServerDiffLine]) -> [DiffEntry] {
    var entries: [DiffEntry] = []
    var contextRun = 0
    var hadChange = false

    for (index, line) in diffLines.enumerated() {
      let kind: DiffEntry.EntryKind = switch line.type {
        case .context: .context
        case .addition: .addition
        case .deletion: .deletion
      }

      let isChange = kind == .addition || kind == .deletion

      // Insert hunk separator when change follows 2+ context lines after a previous change
      if isChange && contextRun >= 2 && hadChange {
        entries.append(DiffEntry(
          id: index * 1000 + 999, kind: .separator,
          oldLine: nil, newLine: nil, content: ""
        ))
      }

      entries.append(DiffEntry(
        id: index, kind: kind,
        oldLine: line.oldLine, newLine: line.newLine,
        content: line.content
      ))

      if isChange {
        contextRun = 0
        hadChange = true
      } else {
        contextRun += 1
      }
    }

    return entries
  }

  /// Compute word-level diff segments for a deletion line if the next entry is an addition.
  private func wordDiffSegments(entries: [DiffEntry], at index: Int) -> [WordLevelDiff.Segment]? {
    let entry = entries[index]
    guard entry.kind == .deletion else { return nil }
    let nextIdx = index + 1
    guard nextIdx < entries.count, entries[nextIdx].kind == .addition else { return nil }
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

      if let diffLines = content.diffDisplay, !diffLines.isEmpty {
        diffView(diffLines)
      }

      if let output = content.outputDisplay, !output.isEmpty {
        codeBlock(label: "Result", text: output)
      }
    }
  }

  // MARK: - Diff View

  @ViewBuilder
  private func diffView(_ diffLines: [ServerDiffLine]) -> some View {
    let adds = diffLines.filter { $0.type == .addition }.count
    let dels = diffLines.filter { $0.type == .deletion }.count
    let entries = buildEntries(from: diffLines)
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
            if entry.kind == .separator {
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
        if diffLines.count > 30 {
          DiffChangeStrip(lines: diffLines, height: 400)
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
      // ── Line number ──
      let lineNum = entry.kind == .deletion ? entry.oldLine : entry.newLine
      Text(lineNum.map { "\($0)" } ?? "")
        .font(.system(size: TypeScale.code, design: .monospaced))
        .foregroundStyle(lineColor(entry.kind).opacity(0.4))
        .frame(width: gutter, alignment: .trailing)
        .padding(.trailing, Spacing.xs)

      // ── Edge bar (doubles as gutter divider — colored for changes, neutral for context) ──
      Rectangle()
        .fill(entry.kind == .context || entry.kind == .separator
          ? Color.textQuaternary.opacity(0.08)
          : edgeColor(entry.kind))
        .frame(width: 3)

      // ── Content ──
      if let segments = wordDiff {
        wordLevelContent(segments: segments, kind: entry.kind)
          .padding(.leading, Spacing.sm_)
      } else if let lang, !lang.isEmpty, !entry.content.isEmpty {
        let highlighted = SyntaxHighlighter.highlightLine(entry.content, language: lang)
        Text(highlighted)
          .padding(.leading, Spacing.sm_)
      } else {
        Text(entry.content.isEmpty ? " " : entry.content)
          .font(.system(size: TypeScale.code, design: .monospaced))
          .foregroundStyle(lineColor(entry.kind))
          .padding(.leading, Spacing.sm_)
      }
    }
    .padding(.vertical, 1)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(lineBg(entry.kind))
  }

  // MARK: - Hunk Separator

  private func hunkSeparator(gutter: CGFloat) -> some View {
    HStack(spacing: 0) {
      Color.clear
        .frame(width: gutter + Spacing.xs)

      // Neutral divider bar (matches edge bar position)
      Rectangle()
        .fill(Color.textQuaternary.opacity(0.08))
        .frame(width: 3)

      Spacer()
      Text("\u{22EF}")
        .font(.system(size: TypeScale.caption, design: .monospaced))
        .foregroundStyle(Color.textQuaternary.opacity(0.3))
      Spacer()
    }
    .frame(height: Spacing.lg)
    .background(Color.textQuaternary.opacity(0.02))
  }

  // MARK: - Word-Level Diff

  @ViewBuilder
  private func wordLevelContent(segments: [WordLevelDiff.Segment], kind: DiffEntry.EntryKind) -> some View {
    let highlightColor: Color = kind == .deletion ? .diffRemovedHighlight : .diffAddedHighlight
    let textColor = lineColor(kind)

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

  private func lineColor(_ kind: DiffEntry.EntryKind) -> Color {
    switch kind {
    case .addition: .diffAddedAccent
    case .deletion: .diffRemovedAccent
    case .context, .separator: .textTertiary
    }
  }

  private func lineBg(_ kind: DiffEntry.EntryKind) -> Color {
    switch kind {
    case .addition: .diffAddedBg
    case .deletion: .diffRemovedBg
    case .context, .separator: .clear
    }
  }

  private func edgeColor(_ kind: DiffEntry.EntryKind) -> Color {
    switch kind {
    case .addition: .diffAddedEdge
    case .deletion: .diffRemovedEdge
    case .context, .separator: .clear
    }
  }
}
