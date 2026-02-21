//
//  MarkdownView.swift
//  OrbitDock
//
//  Markdown rendering using swift-markdown (cmark-gfm) AST.
//  Replaces MarkdownUI with direct AST walking into SwiftUI views.

import Markdown
import SwiftUI

// MARK: - Style

enum MarkdownStyle: Hashable {
  case standard
  case thinking
}

// MARK: - Main Markdown View

struct MarkdownContentView: View, Equatable {
  let content: String
  var style: MarkdownStyle = .standard

  var body: some View {
    let document = Document(parsing: content)
    MarkdownDocumentView(document: document, style: style)
      .textSelection(.enabled)
      .environment(\.openURL, OpenURLAction { url in
        Platform.services.openURL(url) ? .handled : .systemAction
      })
  }
}

/// Alias for backwards compatibility
typealias MarkdownView = MarkdownContentView

// MARK: - Streaming Markdown View

/// Throttles rapid markdown updates and adds a subtle fade-in to smooth streaming text.
struct StreamingMarkdownView: View {
  let content: String
  var style: Style = .standard
  var cadence: Duration = .milliseconds(150)

  enum Style {
    case standard
    case thinking
  }

  @State private var renderedContent: String
  @State private var pendingContent: String
  @State private var updateTask: Task<Void, Never>?
  @State private var fadeOpacity: Double = 1.0

  init(content: String, style: Style = .standard, cadence: Duration = .milliseconds(150)) {
    self.content = content
    self.style = style
    self.cadence = cadence
    _renderedContent = State(initialValue: content)
    _pendingContent = State(initialValue: content)
  }

  var body: some View {
    Group {
      switch style {
        case .standard:
          MarkdownContentView(content: renderedContent)
            .equatable()
        case .thinking:
          ThinkingMarkdownView(content: renderedContent)
            .equatable()
      }
    }
    .opacity(fadeOpacity)
    .onAppear {
      if renderedContent != content || pendingContent != content {
        renderedContent = content
        pendingContent = content
      }
      fadeOpacity = 1.0
    }
    .onDisappear {
      updateTask?.cancel()
      updateTask = nil
    }
    .onChange(of: content) { _, newContent in
      queueRender(newContent)
    }
  }

  private func queueRender(_ newContent: String) {
    pendingContent = newContent
    guard updateTask == nil else { return }

    updateTask = Task { @MainActor in
      defer { updateTask = nil }

      while !Task.isCancelled, renderedContent != pendingContent {
        renderedContent = pendingContent
        fadeOpacity = 0.82
        withAnimation(.easeInOut(duration: 0.18)) {
          fadeOpacity = 1.0
        }
        try? await Task.sleep(for: cadence)
      }
    }
  }
}

// MARK: - Thinking Markdown View (Compact theme)

struct ThinkingMarkdownView: View, Equatable {
  let content: String

  var body: some View {
    MarkdownContentView(content: content, style: .thinking)
  }
}

// MARK: - Document View

/// Iterates top-level block children and dispatches to per-block views.
private struct MarkdownDocumentView: View {
  let document: Document
  let style: MarkdownStyle

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(document.children.enumerated()), id: \.offset) { _, block in
        blockView(for: block)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func blockView(for markup: any Markup) -> some View {
    switch markup {
      case let heading as Heading:
        MarkdownHeadingView(heading: heading, style: style)

      case let paragraph as Paragraph:
        MarkdownParagraphView(paragraph: paragraph, style: style)
          .padding(.bottom, style == .thinking ? 6 : 12)

      case let codeBlock as CodeBlock:
        let lang = codeBlock.language.flatMap { l in
          let trimmed = l.trimmingCharacters(in: .whitespaces)
          return trimmed.isEmpty ? nil : trimmed
        }
        CodeBlockView(language: lang, code: trimCodeBlock(codeBlock.code))
          .padding(.vertical, style == .thinking ? 6 : 12)

      case let blockQuote as BlockQuote:
        MarkdownBlockQuoteView(blockQuote: blockQuote, style: style)
          .padding(.vertical, style == .thinking ? 5 : 10)

      case let orderedList as OrderedList:
        MarkdownOrderedListView(list: orderedList, style: style)
          .padding(.bottom, style == .thinking ? 6 : 12)

      case let unorderedList as UnorderedList:
        MarkdownUnorderedListView(list: unorderedList, style: style)
          .padding(.bottom, style == .thinking ? 6 : 12)

      case is ThematicBreak:
        HorizontalDivider()
          .padding(.vertical, style == .thinking ? 8 : 14)

      case let table as Markdown.Table:
        MarkdownTableView(table: table, style: style)
          .padding(.vertical, style == .thinking ? 6 : 12)

      case let htmlBlock as HTMLBlock:
        Text(htmlBlock.rawHTML)
          .font(.system(size: bodyFontSize(style)))
          .foregroundStyle(textColor(style))
          .padding(.bottom, style == .thinking ? 6 : 10)

      default:
        EmptyView()
    }
  }

  private func trimCodeBlock(_ code: String) -> String {
    var result = code
    while result.hasSuffix("\n") {
      result = String(result.dropLast())
    }
    return result
  }
}

// MARK: - Heading View

private struct MarkdownHeadingView: View {
  let heading: Heading
  let style: MarkdownStyle

  var body: some View {
    let level = min(heading.level, 3)
    inlineText(for: heading, style: style)
      .font(headingFont(level: level, style: style))
      .kerning(headingKerning(level: level, style: style))
      .foregroundStyle(headingColor(level: level, style: style))
      .padding(.top, headingTopMargin(level: level, style: style))
      .padding(.bottom, headingBottomMargin(level: level, style: style))
  }
}

// MARK: - Paragraph View

private struct MarkdownParagraphView: View {
  let paragraph: Paragraph
  let style: MarkdownStyle

  var body: some View {
    let hasLinks = paragraph.children.contains { $0 is Markdown.Link }

    if hasLinks {
      // Use AttributedString for tappable links
      SwiftUI.Text(attributedString(for: paragraph, style: style))
        .font(.system(size: bodyFontSize(style)))
        .lineSpacing(style == .thinking ? 2 : 4)
    } else {
      inlineText(for: paragraph, style: style)
        .font(.system(size: bodyFontSize(style)))
        .foregroundStyle(textColor(style))
        .lineSpacing(style == .thinking ? 2 : 4)
    }
  }
}

// MARK: - Block Quote View

private struct MarkdownBlockQuoteView: View {
  let blockQuote: BlockQuote
  let style: MarkdownStyle

  var body: some View {
    HStack(spacing: 0) {
      RoundedRectangle(cornerRadius: 2)
        .fill(style == .thinking ? Color.textTertiary.opacity(0.5) : Color.accentMuted.opacity(0.9))
        .frame(width: style == .thinking ? 2 : 3)
      VStack(alignment: .leading, spacing: 4) {
        ForEach(Array(blockQuote.children.enumerated()), id: \.offset) { _, child in
          if let para = child as? Paragraph {
            inlineText(for: para, style: style)
              .font(.system(size: style == .thinking ? TypeScale.code : TypeScale.reading))
              .italic()
              .foregroundStyle(style == .thinking ? Color.textSecondary.opacity(0.8) : Color.textSecondary.opacity(0.9))
          }
        }
      }
      .padding(.leading, style == .thinking ? 10 : 14)
    }
  }
}

// MARK: - Ordered List View

private struct MarkdownOrderedListView: View {
  let list: OrderedList
  let style: MarkdownStyle

  var body: some View {
    VStack(alignment: .leading, spacing: style == .thinking ? 1 : 4) {
      ForEach(Array(list.listItems.enumerated()), id: \.offset) { idx, item in
        let number = Int(list.startIndex) + idx
        MarkdownListItemView(item: item, bullet: "\(number).", style: style)
      }
    }
  }
}

// MARK: - Unordered List View

private struct MarkdownUnorderedListView: View {
  let list: UnorderedList
  let style: MarkdownStyle

  var body: some View {
    VStack(alignment: .leading, spacing: style == .thinking ? 1 : 4) {
      ForEach(Array(list.listItems.enumerated()), id: \.offset) { _, item in
        if let checkbox = item.checkbox {
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            TaskListCheckbox(isCompleted: checkbox == .checked)
            listItemContent(item)
          }
          .padding(.vertical, style == .thinking ? 1 : 2)
        } else {
          MarkdownListItemView(item: item, bullet: "\u{2022}", style: style)
        }
      }
    }
  }

  private func listItemContent(_ item: ListItem) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(Array(item.children.enumerated()), id: \.offset) { _, child in
        if let para = child as? Paragraph {
          inlineText(for: para, style: style)
            .font(.system(size: bodyFontSize(style)))
            .foregroundStyle(textColor(style))
        }
      }
    }
  }
}

// MARK: - List Item View

private struct MarkdownListItemView: View {
  let item: ListItem
  let bullet: String
  let style: MarkdownStyle

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(bullet)
        .font(.system(size: bodyFontSize(style), design: .monospaced))
        .foregroundStyle(Color.textTertiary)
        .frame(minWidth: 16, alignment: .trailing)
      VStack(alignment: .leading, spacing: 2) {
        ForEach(Array(item.children.enumerated()), id: \.offset) { _, child in
          if let para = child as? Paragraph {
            let hasLinks = para.children.contains { $0 is Markdown.Link }

            if hasLinks {
              SwiftUI.Text(attributedString(for: para, style: style))
                .font(.system(size: bodyFontSize(style)))
                .lineSpacing(style == .thinking ? 2 : 4)
            } else {
              inlineText(for: para, style: style)
                .font(.system(size: bodyFontSize(style)))
                .foregroundStyle(textColor(style))
            }
          }
        }
      }
    }
    .padding(.vertical, style == .thinking ? 1 : 2)
  }
}

// MARK: - Table View

private struct MarkdownTableView: View {
  let table: Markdown.Table
  let style: MarkdownStyle

  private var headers: [String] {
    Array(table.head.cells.map { $0.plainText.trimmingCharacters(in: .whitespaces) })
  }

  private var rows: [[String]] {
    let headerCount = headers.count
    return table.body.rows.map { row in
      let cells: [String] = Array(row.cells.map { $0.plainText.trimmingCharacters(in: .whitespaces) })
      let padded = cells + Array(repeating: "", count: max(0, headerCount - cells.count))
      return Array(padded.prefix(headerCount))
    }
  }

  var body: some View {
    let allHeaders = headers
    let allRows = rows

    VStack(alignment: .leading, spacing: 0) {
      // Header row
      HStack(spacing: 0) {
        ForEach(Array(allHeaders.enumerated()), id: \.offset) { _, header in
          Text(header)
            .font(.system(size: bodyFontSize(style), weight: .semibold))
            .foregroundStyle(textColor(style))
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .background(Color.white.opacity(0.05))

      // Data rows
      ForEach(Array(allRows.enumerated()), id: \.offset) { rowIdx, row in
        HStack(spacing: 0) {
          ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
            Text(cell)
              .font(.system(size: bodyFontSize(style)))
              .foregroundStyle(textColor(style))
              .padding(.vertical, 8)
              .padding(.horizontal, 12)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .background(rowIdx % 2 == 0 ? Color.white.opacity(0.02) : Color.white.opacity(0.05))
      }
    }
    .overlay(
      RoundedRectangle(cornerRadius: 4)
        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: 4))
  }
}

// MARK: - Inline Text Rendering

/// Concatenates inline children of a markup node into a single SwiftUI `Text`.
private func inlineText(for markup: any Markup, style: MarkdownStyle) -> SwiftUI.Text {
  var result = SwiftUI.Text("")
  for child in markup.children {
    result = Text("\(result)\(inlineSegment(for: child, style: style))")
  }
  return result
}

private func inlineSegment(for markup: any Markup, style: MarkdownStyle) -> SwiftUI.Text {
  switch markup {
    case let text as Markdown.Text:
      return SwiftUI.Text(text.string)

    case let strong as Strong:
      var inner = SwiftUI.Text("")
      for child in strong.children {
        inner = Text("\(inner)\(inlineSegment(for: child, style: style))")
      }
      return inner.bold()

    case let emphasis as Emphasis:
      var inner = SwiftUI.Text("")
      for child in emphasis.children {
        inner = Text("\(inner)\(inlineSegment(for: child, style: style))")
      }
      return inner.italic()

    case let code as InlineCode:
      return SwiftUI.Text(code.code)
        .font(.system(size: style == .thinking ? TypeScale.caption : TypeScale.chatCode, design: .monospaced))
        .foregroundColor(style == .thinking ? Color(red: 0.85, green: 0.6, blue: 0.4) : Color(
          red: 0.95,
          green: 0.68,
          blue: 0.45
        ))

    case let link as Markdown.Link:
      var inner = SwiftUI.Text("")
      for child in link.children {
        inner = Text("\(inner)\(inlineSegment(for: child, style: style))")
      }
      return inner.foregroundColor(style == .thinking ? Color(red: 0.5, green: 0.65, blue: 0.85) : Color(
        red: 0.5,
        green: 0.72,
        blue: 0.95
      ))
      .underline()

    case let image as Markdown.Image:
      return SwiftUI.Text(image.plainText)
        .foregroundColor(Color(red: 0.5, green: 0.72, blue: 0.95))
        .underline()

    case let strikethrough as Markdown.Strikethrough:
      var inner = SwiftUI.Text("")
      for child in strikethrough.children {
        inner = Text("\(inner)\(inlineSegment(for: child, style: style))")
      }
      return inner.strikethrough()

    case is SoftBreak:
      return SwiftUI.Text(" ")

    case is LineBreak:
      return SwiftUI.Text("\n")

    case let html as InlineHTML:
      return SwiftUI.Text(html.rawHTML)

    default:
      // Recurse children for unknown inline containers, or render format() for leaf nodes
      var inner = SwiftUI.Text("")
      let children = Array(markup.children)
      if !children.isEmpty {
        for child in children {
          inner = Text("\(inner)\(inlineSegment(for: child, style: style))")
        }
      } else {
        inner = SwiftUI.Text(markup.format())
      }
      return inner
  }
}

// MARK: - AttributedString for Links

/// Produces an AttributedString with tappable links by walking inline children.
private func attributedString(for markup: any Markup, style: MarkdownStyle) -> AttributedString {
  var result = AttributedString()
  for child in markup.children {
    result += inlineAttributedString(for: child, style: style)
  }
  return result
}

private func inlineAttributedString(
  for markup: any Markup,
  style: MarkdownStyle,
  bold: Bool = false,
  italic: Bool = false
) -> AttributedString {
  switch markup {
    case let text as Markdown.Text:
      var attr = AttributedString(text.string)
      attr.foregroundColor = textColor(style)
      if bold, italic {
        attr.font = .system(size: bodyFontSize(style), weight: .bold).italic()
      } else if bold {
        attr.font = .system(size: bodyFontSize(style), weight: .bold)
      } else if italic {
        attr.font = .system(size: bodyFontSize(style)).italic()
      }
      return attr

    case let strong as Strong:
      var combined = AttributedString()
      for child in strong.children {
        combined += inlineAttributedString(for: child, style: style, bold: true, italic: italic)
      }
      return combined

    case let emphasis as Emphasis:
      var combined = AttributedString()
      for child in emphasis.children {
        combined += inlineAttributedString(for: child, style: style, bold: bold, italic: true)
      }
      return combined

    case let code as InlineCode:
      var attr = AttributedString(code.code)
      attr.font = .system(size: style == .thinking ? TypeScale.caption : TypeScale.chatCode, design: .monospaced)
      attr.foregroundColor = style == .thinking ? Color(red: 0.85, green: 0.6, blue: 0.4) : Color(
        red: 0.95,
        green: 0.68,
        blue: 0.45
      )
      attr.backgroundColor = Color.white.opacity(style == .thinking ? 0.05 : 0.09)
      return attr

    case let link as Markdown.Link:
      var combined = AttributedString()
      for child in link.children {
        combined += inlineAttributedString(for: child, style: style, bold: bold, italic: italic)
      }
      let linkColor = style == .thinking ? Color(red: 0.5, green: 0.65, blue: 0.85) : Color(
        red: 0.5,
        green: 0.72,
        blue: 0.95
      )
      combined.foregroundColor = linkColor
      combined.underlineStyle = .single
      if let dest = link.destination, let url = URL(string: dest) {
        combined.link = url
      }
      return combined

    case let strikethrough as Markdown.Strikethrough:
      var combined = AttributedString()
      for child in strikethrough.children {
        combined += inlineAttributedString(for: child, style: style, bold: bold, italic: italic)
      }
      combined.strikethroughStyle = .single
      return combined

    case is SoftBreak:
      return AttributedString(" ")

    case is LineBreak:
      return AttributedString("\n")

    case let html as InlineHTML:
      var attr = AttributedString(html.rawHTML)
      attr.foregroundColor = textColor(style)
      return attr

    default:
      var combined = AttributedString()
      let children = Array(markup.children)
      if !children.isEmpty {
        for child in children {
          combined += inlineAttributedString(for: child, style: style, bold: bold, italic: italic)
        }
      } else {
        combined = AttributedString(markup.format())
        combined.foregroundColor = textColor(style)
      }
      return combined
  }
}

// MARK: - Style Helpers

private func bodyFontSize(_ style: MarkdownStyle) -> CGFloat {
  style == .thinking ? TypeScale.code : TypeScale.chatBody
}

private func textColor(_ style: MarkdownStyle) -> Color {
  style == .thinking ? Color.textSecondary : Color.textPrimary
}

private func headingFont(level: Int, style: MarkdownStyle) -> Font {
  let isThinking = style == .thinking
  switch level {
    case 1:
      return .system(size: isThinking ? TypeScale.subhead : TypeScale.chatHeading1, weight: .bold, design: .serif)
    case 2:
      return .system(size: isThinking ? TypeScale.body : TypeScale.chatHeading2, weight: .semibold, design: .serif)
    default:
      return .system(size: isThinking ? TypeScale.code : TypeScale.chatHeading3, weight: .bold)
  }
}

private func headingColor(level: Int, style: MarkdownStyle) -> Color {
  let isThinking = style == .thinking
  switch level {
    case 1: return isThinking ? Color.textSecondary : Color.textPrimary
    case 2: return isThinking ? Color.textSecondary.opacity(0.9) : Color.textPrimary.opacity(0.95)
    default: return isThinking ? Color.textSecondary : Color.textPrimary.opacity(0.88)
  }
}

private func headingTopMargin(level: Int, style: MarkdownStyle) -> CGFloat {
  let isThinking = style == .thinking
  switch level {
    case 1: return isThinking ? 10 : 26
    case 2: return isThinking ? 8 : 22
    default: return isThinking ? 6 : 16
  }
}

private func headingBottomMargin(level: Int, style: MarkdownStyle) -> CGFloat {
  let isThinking = style == .thinking
  switch level {
    case 1: return isThinking ? 5 : 14
    case 2: return isThinking ? 4 : 10
    default: return isThinking ? 3 : 8
  }
}

private func headingKerning(level: Int, style: MarkdownStyle) -> CGFloat {
  guard style != .thinking else { return 0 }
  switch level {
    case 1: return 0.3
    case 2: return 0.2
    default: return 0.5
  }
}

// MARK: - Task List Checkbox

struct TaskListCheckbox: View {
  let isCompleted: Bool

  var body: some View {
    Image(systemName: isCompleted ? "checkmark.square.fill" : "square")
      .font(.system(size: 14, weight: .medium))
      .foregroundStyle(isCompleted ? Color.green : Color.secondary.opacity(0.7))
      .frame(width: 20)
  }
}

// MARK: - Horizontal Divider

struct HorizontalDivider: View {
  var body: some View {
    HStack(spacing: 8) {
      ForEach(0 ..< 3, id: \.self) { _ in
        Circle()
          .fill(Color.secondary.opacity(0.4))
          .frame(width: 4, height: 4)
      }
    }
    .frame(maxWidth: .infinity)
  }
}

// MARK: - Code Block View

struct CodeBlockView: View {
  let language: String?
  let code: String

  @State private var isHovering = false
  @State private var copied = false
  @State private var isExpanded = false

  private let collapseThreshold = 15
  private let collapsedLineCount = 8

  private var lines: [String] {
    code.components(separatedBy: "\n")
  }

  private var shouldCollapse: Bool {
    lines.count > collapseThreshold
  }

  private var displayedCode: String {
    if shouldCollapse, !isExpanded {
      return lines.prefix(collapsedLineCount).joined(separator: "\n")
    }
    return code
  }

  private var normalizedLanguage: String? {
    guard let lang = language?.lowercased() else { return nil }
    switch lang {
      case "js": return "javascript"
      case "ts": return "typescript"
      case "tsx": return "typescript"
      case "jsx": return "javascript"
      case "sh", "shell", "zsh": return "bash"
      case "py": return "python"
      case "rb": return "ruby"
      case "yml": return "yaml"
      case "md": return "markdown"
      case "objective-c", "objc": return "objectivec"
      default: return lang
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header

      Divider()
        .opacity(0.3)

      codeContent

      if shouldCollapse {
        expandCollapseButton
      }
    }
    .background(Color(red: 0.06, green: 0.06, blue: 0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
    )
    .onHover { isHovering = $0 }
  }

  private var header: some View {
    HStack(spacing: 10) {
      if let lang = normalizedLanguage ?? language, !lang.isEmpty {
        HStack(spacing: 5) {
          Circle()
            .fill(languageColor(lang))
            .frame(width: 8, height: 8)
          Text(lang)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
        }
      }

      Spacer()

      Text("\(lines.count) lines")
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.tertiary)

      Button {
        Platform.services.copyToClipboard(code)
        copied = true
      } label: {
        HStack(spacing: 5) {
          Image(systemName: copied ? "checkmark" : "doc.on.doc")
            .font(.system(size: 10, weight: .medium))
            .contentTransition(.symbolEffect(.replace))
          if copied {
            Text("Copied")
              .font(.system(size: 10, weight: .medium))
              .transition(.opacity.combined(with: .scale(scale: 0.8)))
          }
        }
        .foregroundStyle(copied ? .green : .secondary)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: copied)
      }
      .buttonStyle(.plain)
      .opacity(isHovering || copied ? 1 : 0)
      .animation(.easeOut(duration: 0.15), value: isHovering)
      .onChange(of: isHovering) { _, newValue in
        if !newValue { copied = false }
      }
    }
    .padding(.horizontal, 14)
    .padding(.top, 10)
    .padding(.bottom, 8)
  }

  private var codeContent: some View {
    let displayLines = displayedCode.components(separatedBy: "\n")
    let maxLineNumWidth = "\(lines.count)".count

    return ScrollView([.horizontal], showsIndicators: false) {
      HStack(alignment: .top, spacing: 0) {
        VStack(alignment: .trailing, spacing: 0) {
          ForEach(Array(displayLines.enumerated()), id: \.offset) { index, _ in
            Text("\(index + 1)")
              .font(.system(size: 11, weight: .regular, design: .monospaced))
              .foregroundStyle(.white.opacity(0.35))
              .frame(width: CGFloat(maxLineNumWidth) * 8 + 10, alignment: .trailing)
              .frame(height: 18)
          }
        }
        .padding(.trailing, 14)
        .padding(.leading, 10)
        .background(Color.white.opacity(0.02))

        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(displayLines.enumerated()), id: \.offset) { _, line in
            Text(SyntaxHighlighter.highlightLine(line, language: normalizedLanguage))
              .font(.system(size: 12.5, design: .monospaced))
              .lineLimit(1)
              .fixedSize(horizontal: true, vertical: false)
              .frame(height: 18, alignment: .leading)
          }
        }
        .layoutPriority(1)
        .textSelection(.enabled)
        .padding(.horizontal, 14)
      }
      .padding(.vertical, 10)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(maxHeight: shouldCollapse && !isExpanded ? CGFloat(collapsedLineCount) * 18 + 24 : min(
      CGFloat(lines.count) * 18 + 24,
      550
    ))
  }

  private var expandCollapseButton: some View {
    Button {
      withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
        isExpanded.toggle()
      }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
          .font(.system(size: 9, weight: .bold))
        Text(isExpanded ? "Show less" : "Show \(lines.count - collapsedLineCount) more lines")
          .font(.system(size: 11, weight: .medium))
      }
      .foregroundStyle(.tertiary)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 10)
      .background(Color.white.opacity(0.03))
    }
    .buttonStyle(.plain)
  }

  private func languageColor(_ lang: String) -> Color {
    switch lang.lowercased() {
      case "swift": .orange
      case "javascript", "typescript": .yellow
      case "python": .blue
      case "ruby": .red
      case "go": .cyan
      case "rust": .orange
      case "bash": .green
      case "json": .purple
      case "html": .red
      case "css": .blue
      case "sql": .cyan
      default: .secondary
    }
  }
}

// MARK: - Preview

#Preview {
  ScrollView {
    VStack(alignment: .leading, spacing: 24) {
      MarkdownContentView(content: """
      ## Markdown Rendering

      Here's a **bold statement** and some *italic text*.

      Check out this `inline code` example and a [link](https://example.com).

      ---

      ### Task List

      - [x] Completed task
      - [ ] Incomplete task
      - [x] Another done item

      | Language | Highlights |
      |----------|-----------|
      | Swift | Keywords, types |
      | JavaScript | ES6+, async/await |

      ```swift
      import SwiftUI

      struct ContentView: View {
          @State private var count = 0
          @State private var name = "World"

          var body: some View {
              VStack(spacing: 20) {
                  Text("Hello, \\(name)!")
                      .font(.largeTitle)

                  Button("Count: \\(count)") {
                      count += 1
                  }

                  // This is a comment
                  ForEach(0..<5) { index in
                      Text("Item \\(index)")
                  }
              }
              .padding()
          }
      }
      ```

      > This is a blockquote with some important information.

      - List item one
      - List item two
      - List item three
      """)
    }
    .padding()
  }
  .frame(width: 600, height: 900)
  .background(Color(red: 0.11, green: 0.11, blue: 0.12))
}
