//
//  SwiftUICodeBlockView.swift
//  OrbitDock
//
//  Pure SwiftUI code block with header, syntax highlighting,
//  line numbers, expand/collapse, and copy button.
//
//  Performance: line numbers and code are each a single Text view
//  (not per-line HStacks) to minimise CALayer backing store count.
//

import SwiftUI

struct SwiftUICodeBlockView: View {
  let language: String?
  let code: String

  private static let collapseThreshold = 15
  private static let collapsedLineCount = 8
  private static let lineSpacing: CGFloat = 5

  @State private var isExpanded = false
  @State private var copyLabel = "Copy"

  private var normalizedLanguage: String? {
    MarkdownLanguage.normalize(language)
  }

  private var allLines: [String] {
    code.components(separatedBy: "\n")
  }

  private var shouldCollapse: Bool {
    allLines.count > Self.collapseThreshold
  }

  private var visibleCount: Int {
    shouldCollapse && !isExpanded ? Self.collapsedLineCount : allLines.count
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      separator
      codeBody
      if shouldCollapse {
        expandButton
      }
    }
    .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.sm))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.sm)
        .stroke(Color.surfaceBorder, lineWidth: 1)
    )
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 5) {
      if let lang = normalizedLanguage, !lang.isEmpty {
        Circle()
          .fill(MarkdownLanguage.badgeColor(lang))
          .frame(width: 8, height: 8)

        Text(lang)
          .font(.system(size: TypeScale.meta, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.textSecondary)
      }

      Spacer()

      Text(allLines.count == 1 ? "1 line" : "\(allLines.count) lines")
        .font(.system(size: TypeScale.meta, weight: .medium))
        .foregroundStyle(Color.textTertiary)

      Button(copyLabel) {
        #if os(macOS)
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(code, forType: .string)
        #else
          UIPasteboard.general.string = code
        #endif
        copyLabel = "Copied"
      }
      .buttonStyle(.plain)
      .font(.system(size: TypeScale.meta, weight: .medium))
      .foregroundStyle(Color.textSecondary)
    }
    .padding(.horizontal, 14)
    .frame(height: 36)
  }

  private var separator: some View {
    Rectangle()
      .fill(Color.white.opacity(0.06))
      .frame(height: 1)
  }

  // MARK: - Code Body (single Text views, not per-line)

  private var codeBody: some View {
    let count = visibleCount
    let gutterChars = max(2, "\(allLines.count)".count)
    let gutterWidth = CGFloat(gutterChars) * 8 + 10 + 14  // content + trailing pad

    return HStack(alignment: .top, spacing: 0) {
      // Line numbers — single Text
      Text(buildLineNumbers(count: count))
        .lineSpacing(Self.lineSpacing)
        .multilineTextAlignment(.trailing)
        .frame(width: gutterWidth, alignment: .trailing)
        .padding(.trailing, 4)
        .background(Color.backgroundTertiary.opacity(0.4))

      // Vertical divider
      Color.textQuaternary.opacity(0.08)
        .frame(width: 1)

      // Code — single Text, horizontally scrollable
      ScrollView(.horizontal, showsIndicators: true) {
        Text(buildCodeText(count: count))
          .lineSpacing(Self.lineSpacing)
          .fixedSize(horizontal: true, vertical: false)
          .padding(.leading, Spacing.sm)
          .padding(.trailing, 14)
      }
    }
    .padding(.vertical, 10)
    .transaction { $0.animation = nil }
  }

  // MARK: - Attributed String Builders

  private func buildLineNumbers(count: Int) -> AttributedString {
    var result = AttributedString()
    for i in 0 ..< count {
      if i > 0 {
        var nl = AttributedString("\n")
        nl.font = .system(size: TypeScale.code, design: .monospaced)
        result.append(nl)
      }
      var num = AttributedString("\(i + 1)")
      num.font = .system(size: TypeScale.code, design: .monospaced)
      num.foregroundColor = Color.textTertiary
      result.append(num)
    }
    return result
  }

  private func buildCodeText(count: Int) -> AttributedString {
    var result = AttributedString()
    let lang = normalizedLanguage
    for i in 0 ..< count {
      if i > 0 {
        var nl = AttributedString("\n")
        nl.font = .system(size: TypeScale.code, design: .monospaced)
        result.append(nl)
      }
      let line = allLines[i]
      if let lang, !lang.isEmpty, !line.isEmpty {
        result.append(SyntaxHighlighter.highlightLine(line, language: lang))
      } else {
        var plain = AttributedString(line.isEmpty ? " " : line)
        plain.font = .system(size: TypeScale.code, design: .monospaced)
        plain.foregroundColor = Color.textSecondary
        result.append(plain)
      }
    }
    return result
  }

  // MARK: - Expand/Collapse

  private var expandButton: some View {
    Button {
      isExpanded.toggle()
    } label: {
      Text(isExpanded ? "Show less" : "Show \(allLines.count - Self.collapsedLineCount) more lines")
        .font(.system(size: TypeScale.meta, weight: .medium))
        .foregroundStyle(Color.textTertiary)
        .frame(maxWidth: .infinity)
        .frame(height: 34)
    }
    .buttonStyle(.plain)
    .transaction { $0.animation = nil }
  }
}
