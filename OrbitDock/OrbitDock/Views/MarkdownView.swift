//
//  MarkdownView.swift
//  OrbitDock
//
//  Shared markdown rendering for SwiftUI surfaces using MarkdownSystemParser blocks.
//

import SwiftUI

// MARK: - Main Markdown View

struct MarkdownContentView: View, Equatable {
  let content: String
  var style: ContentStyle = .standard

  var body: some View {
    let blocks = MarkdownSystemParser.parse(content, style: style)

    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        MarkdownBlockSwiftUIView(block: block, style: style)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .textSelection(.enabled)
    .environment(\.openURL, OpenURLAction { url in
      Platform.services.openURL(url) ? .handled : .systemAction
    })
  }
}

// MARK: - Streaming

struct StreamingMarkdownView: View {
  let content: String
  var style: ContentStyle = .standard
  var cadence: Duration = .milliseconds(150)

  @State private var renderedContent: String
  @State private var pendingContent: String
  @State private var updateTask: Task<Void, Never>?
  @State private var fadeOpacity: Double = 1.0

  init(content: String, style: ContentStyle = .standard, cadence: Duration = .milliseconds(150)) {
    self.content = content
    self.style = style
    self.cadence = cadence
    _renderedContent = State(initialValue: content)
    _pendingContent = State(initialValue: content)
  }

  var body: some View {
    MarkdownContentView(content: renderedContent, style: style)
      .equatable()
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

struct ThinkingMarkdownView: View, Equatable {
  let content: String

  var body: some View {
    MarkdownContentView(content: content, style: .thinking)
  }
}

// MARK: - Block Dispatcher

private struct MarkdownBlockSwiftUIView: View {
  let block: MarkdownBlock
  let style: ContentStyle

  var body: some View {
    switch block {
      case let .text(text):
        Text(bridged(text))
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.bottom, MarkdownLayoutMetrics.trailingTextBlockSpacing(text, style: style))

      case let .blockquote(text):
        HStack(alignment: .top, spacing: 0) {
          RoundedRectangle(cornerRadius: 2)
            .fill(style == .thinking ? Color.textTertiary.opacity(0.5) : Color.accentMuted.opacity(0.9))
            .frame(width: MarkdownLayoutMetrics.blockquoteBarWidth(style: style))

          Text(bridged(text))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, MarkdownLayoutMetrics.blockquoteLeadingPadding(style: style))
        }
        .padding(.vertical, MarkdownLayoutMetrics.verticalMargin(for: .blockquote, style: style))

      case let .codeBlock(language, code):
        CodeBlockView(language: language, code: code)
          .padding(.vertical, MarkdownLayoutMetrics.verticalMargin(for: .codeBlock, style: style))

      case let .table(headers, rows):
        MarkdownTableBlockView(headers: headers, rows: rows, style: style)
          .padding(.vertical, MarkdownLayoutMetrics.verticalMargin(for: .table, style: style))

      case .thematicBreak:
        HorizontalDivider()
          .padding(.vertical, MarkdownLayoutMetrics.verticalMargin(for: .thematicBreak, style: style))
    }
  }

  private func bridged(_ ns: NSAttributedString) -> AttributedString {
    (try? AttributedString(ns, including: \.foundation)) ?? AttributedString(ns.string)
  }
}

// MARK: - Table

private struct MarkdownTableBlockView: View {
  let headers: [String]
  let rows: [[String]]
  let style: ContentStyle

  var body: some View {
    let normalizedRows = rows.map { row in
      let padded = row + Array(repeating: "", count: max(0, headers.count - row.count))
      return Array(padded.prefix(headers.count))
    }

    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 0) {
        ForEach(Array(headers.enumerated()), id: \.offset) { index, header in
          HStack(spacing: 0) {
            Text(cellText(header, isHeader: true))
              .padding(.vertical, 10)
              .padding(.horizontal, 14)
              .frame(maxWidth: .infinity, alignment: .leading)
            if index < headers.count - 1 {
              Rectangle()
                .fill(Color.surfaceBorder.opacity(0.55))
                .frame(width: 1)
            }
          }
        }
      }
      .background(Color.backgroundTertiary.opacity(0.68))
      .overlay(alignment: .bottom) {
        Rectangle()
          .fill(Color.surfaceBorder.opacity(0.55))
          .frame(height: 1)
      }

      ForEach(Array(normalizedRows.enumerated()), id: \.offset) { rowIndex, row in
        HStack(spacing: 0) {
          ForEach(Array(row.enumerated()), id: \.offset) { colIndex, cell in
            HStack(spacing: 0) {
              Text(cellText(cell, isHeader: false))
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
              if colIndex < row.count - 1 {
                Rectangle()
                  .fill(Color.surfaceBorder.opacity(0.55))
                  .frame(width: 1)
              }
            }
          }
        }
        .background(rowIndex.isMultiple(of: 2) ? Color.backgroundSecondary.opacity(0.42) : Color.backgroundTertiary.opacity(0.48))
        .overlay(alignment: .bottom) {
          Rectangle()
            .fill(Color.surfaceBorder.opacity(0.55))
            .frame(height: 1)
        }
      }
    }
    .overlay(
      RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
        .strokeBorder(Color.surfaceBorder.opacity(0.9), lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
  }

  private func cellText(_ markdown: String, isHeader: Bool) -> AttributedString {
    let ns = MarkdownSystemParser.inlineTableCellText(from: markdown, style: style, isHeader: isHeader)
    return (try? AttributedString(ns, including: \.foundation)) ?? AttributedString(ns.string)
  }
}

// MARK: - Divider

struct HorizontalDivider: View {
  var body: some View {
    HStack(spacing: 8) {
      ForEach(0 ..< 3, id: \.self) { _ in
        Circle()
          .fill(Color.textQuaternary.opacity(0.6))
          .frame(width: 4, height: 4)
      }
    }
    .frame(maxWidth: .infinity)
  }
}

// MARK: - Code Block

struct CodeBlockView: View {
  let language: String?
  let code: String

  @State private var isHovering = false
  @State private var copied = false
  @State private var isExpanded = false

  private let collapseThreshold = 15
  private let collapsedLineCount = 8
  private let rowHeight: CGFloat = 21

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
    MarkdownLanguage.normalize(language)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header

      Divider()
        .overlay(Color.surfaceBorder.opacity(0.45))

      codeContent

      if shouldCollapse {
        expandCollapseButton
      }
    }
    .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(Color.surfaceBorder.opacity(0.9), lineWidth: 1)
    )
    .onHover { isHovering = $0 }
  }

  private var header: some View {
    HStack(spacing: 10) {
      if let lang = normalizedLanguage, !lang.isEmpty {
        HStack(spacing: 5) {
          Circle()
            .fill(MarkdownLanguage.badgeColor(lang))
            .frame(width: 8, height: 8)

          Text(lang)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.textSecondary)
        }
      }

      Spacer()

      Text(lines.count == 1 ? "1 line" : "\(lines.count) lines")
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(Color.textTertiary)

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
        .foregroundStyle(copied ? Color.statusReply : Color.textSecondary)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: copied)
      }
      .buttonStyle(.plain)
      .opacity(isHovering || copied ? 1 : 0)
      .animation(.easeOut(duration: 0.15), value: isHovering)
      .onChange(of: isHovering) { _, hovering in
        if !hovering { copied = false }
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
              .font(.system(size: 12, weight: .regular, design: .monospaced))
              .foregroundStyle(Color.textQuaternary)
              .frame(width: CGFloat(maxLineNumWidth) * 8 + 10, alignment: .trailing)
              .frame(height: rowHeight)
          }
        }
        .padding(.trailing, 14)
        .padding(.leading, 10)
        .background(Color.backgroundTertiary.opacity(0.4))

        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(displayLines.enumerated()), id: \.offset) { _, rawLine in
            let line = rawLine.isEmpty ? " " : rawLine
            Text(SyntaxHighlighter.highlightLine(line, language: normalizedLanguage))
              .font(.system(size: TypeScale.chatCode, design: .monospaced))
              .lineLimit(1)
              .fixedSize(horizontal: true, vertical: false)
              .frame(height: rowHeight, alignment: .leading)
          }
        }
        .layoutPriority(1)
        .textSelection(.enabled)
        .padding(.horizontal, 14)
      }
      .padding(.vertical, 10)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(maxHeight: shouldCollapse && !isExpanded ? CGFloat(collapsedLineCount) * rowHeight + 24 : min(
      CGFloat(lines.count) * rowHeight + 24,
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
      .foregroundStyle(Color.textTertiary)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 10)
      .background(Color.backgroundTertiary.opacity(0.3))
    }
    .buttonStyle(.plain)
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

          var body: some View {
              VStack(spacing: 20) {
                  Text("Count: \\(count)")
              }
              .padding()
          }
      }
      ```

      > This is a blockquote with some important information.
      """)
    }
    .padding()
  }
  .frame(width: 600, height: 900)
  .background(Color.backgroundPrimary)
}
