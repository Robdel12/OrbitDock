//
//  ToolCardView.swift
//  OrbitDock
//
//  SwiftUI view for tool calls. Reads ServerToolDisplay directly.
//  Compact: accent bar + glyph + summary + subtitle + meta.
//  Expanded: input/output/diff sections.
//

import SwiftUI

struct ToolCardView: View {
  let toolRow: ServerConversationToolRow
  let isExpanded: Bool

  private var display: ServerToolDisplay? { toolRow.toolDisplay }
  private var glyphSymbol: String { display?.glyphSymbol ?? "gearshape" }
  private var glyphColor: Color { Self.resolveColor(display?.glyphColor ?? "gray") }
  private var summary: String { display?.summary ?? toolRow.title }
  private var subtitle: String? { display?.subtitle ?? toolRow.subtitle }
  private var rightMeta: String? { display?.rightMeta }
  private var isRunning: Bool { toolRow.status == .running || toolRow.status == .pending }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      compactRow
      if isExpanded {
        expandedContent
      }
    }
    .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .overlay(alignment: .leading) {
      RoundedRectangle(cornerRadius: 1.5)
        .fill(glyphColor)
        .frame(width: EdgeBar.width)
        .padding(.vertical, Spacing.xs)
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.xxs)
    .contentShape(Rectangle())
  }

  // MARK: - Compact Row

  private var compactRow: some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: glyphSymbol)
        .font(.system(size: IconScale.md))
        .foregroundStyle(glyphColor)
        .frame(width: IconScale.lg)

      VStack(alignment: .leading, spacing: Spacing.xxs) {
        Text(summary)
          .font(display?.summaryFont == "monospace"
            ? .system(size: TypeScale.body, design: .monospaced)
            : .system(size: TypeScale.body, weight: .medium))
          .foregroundStyle(Color.textSecondary)

        if let subtitle, !subtitle.isEmpty {
          Text(subtitle)
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textTertiary)
        }

        // Live output preview for in-progress tools
        if isRunning, let preview = display?.liveOutputPreview ?? display?.outputPreview,
           !preview.isEmpty
        {
          Text(preview)
            .font(.system(size: TypeScale.code, design: .monospaced))
            .foregroundStyle(Color.textTertiary)
            .opacity(0.8)
        }
      }

      Spacer(minLength: 0)

      if let rightMeta, !rightMeta.isEmpty {
        Text(rightMeta)
          .font(.system(size: TypeScale.meta, design: .monospaced))
          .foregroundStyle(Color.textTertiary)
      }

      if isRunning {
        ProgressView()
          .controlSize(.small)
      }

      Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
        .font(.system(size: IconScale.xs, weight: .semibold))
        .foregroundStyle(Color.textQuaternary)
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
  }

  // MARK: - Expanded Content

  @ViewBuilder
  private var expandedContent: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Divider()
        .background(Color.textQuaternary.opacity(0.3))

      if let display {
        if let input = display.inputDisplay, !input.isEmpty {
          monoSection(title: "Input", text: input)
        }
        if let diff = display.diffDisplay, !diff.isEmpty {
          diffSection(text: diff)
        }
        if let output = display.outputDisplay, !output.isEmpty {
          monoSection(title: "Output", text: output)
        }
      } else {
        // Fallback: show raw invocation/result
        if let json = toolRow.invocation.jsonString, !json.isEmpty {
          monoSection(title: "Input", text: json)
        }
        if let json = toolRow.result?.jsonString, !json.isEmpty {
          monoSection(title: "Output", text: json)
        }
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.bottom, Spacing.md)
  }

  // MARK: - Section Views

  private func monoSection(title: String, text: String) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text(title)
        .font(.system(size: TypeScale.caption, weight: .semibold))
        .foregroundStyle(Color.textTertiary)

      ScrollView(.horizontal, showsIndicators: false) {
        Text(clampLines(text, max: 40))
          .font(.system(size: TypeScale.code, design: .monospaced))
          .foregroundStyle(Color.textSecondary)
          .padding(Spacing.sm)
      }
      .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.sm))
    }
  }

  private func diffSection(text: String) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(clampLines(text, max: 60).components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
        HStack(spacing: 0) {
          Text(line)
            .font(.system(size: TypeScale.code, design: .monospaced))
            .foregroundStyle(diffLineColor(line))
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(diffLineBg(line))
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
  }

  // MARK: - Helpers

  private func clampLines(_ text: String, max: Int) -> String {
    let lines = text.components(separatedBy: "\n")
    if lines.count <= max { return text }
    return lines.prefix(max).joined(separator: "\n") + "\n... (\(lines.count - max) more lines)"
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

  static func resolveColor(_ name: String) -> Color {
    switch name {
    case "accent", "cyan": return .accent
    case "green": return .feedbackPositive
    case "orange": return .toolWrite
    case "blue": return .toolRead
    case "purple": return .toolSearch
    case "red": return .feedbackNegative
    case "yellow", "amber": return .feedbackCaution
    case "teal": return .accent
    case "pink": return .toolSkill
    case "gray", "grey": return .textTertiary
    default: return .textTertiary
    }
  }
}

// MARK: - AnyCodable JSON Helper

extension AnyCodable {
  var jsonString: String? {
    guard let data = try? JSONSerialization.data(
      withJSONObject: value, options: [.prettyPrinted, .sortedKeys]
    ) else { return nil }
    return String(data: data, encoding: .utf8)
  }
}
