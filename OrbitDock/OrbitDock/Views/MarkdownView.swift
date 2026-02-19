//
//  MarkdownView.swift
//  OrbitDock
//
//  Markdown rendering using MarkdownUI library

import AppKit
import MarkdownUI
import SwiftUI

// MARK: - Main Markdown View

struct MarkdownContentView: View {
  let content: String

  var body: some View {
    Markdown(content)
      .markdownTheme(.orbitDock)
      .lineSpacing(3)
      .textSelection(.enabled)
      .environment(\.openURL, OpenURLAction { url in
        NSWorkspace.shared.open(url)
        return .handled
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
  var cadence: Duration = .milliseconds(33)

  enum Style {
    case standard
    case thinking
  }

  @State private var renderedContent = ""
  @State private var pendingContent = ""
  @State private var updateTask: Task<Void, Never>?
  @State private var fadeOpacity: Double = 1.0

  var body: some View {
    Group {
      switch style {
        case .standard:
          MarkdownContentView(content: renderedContent)
        case .thinking:
          ThinkingMarkdownView(content: renderedContent)
      }
    }
    .opacity(fadeOpacity)
    .onAppear {
      renderedContent = content
      pendingContent = content
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

struct ThinkingMarkdownView: View {
  let content: String

  var body: some View {
    Markdown(content)
      .markdownTheme(.thinking)
      .lineSpacing(2)
      .textSelection(.enabled)
      .environment(\.openURL, OpenURLAction { url in
        NSWorkspace.shared.open(url)
        return .handled
      })
  }
}

// MARK: - Custom Theme

extension MarkdownUI.Theme {
  /// Compact theme for thinking traces
  static let thinking = Theme()
    .text {
      ForegroundColor(Color.textSecondary)
      FontSize(TypeScale.code)
    }
    .code {
      FontFamilyVariant(.monospaced)
      FontSize(TypeScale.caption)
      ForegroundColor(Color(red: 0.85, green: 0.6, blue: 0.4))
      BackgroundColor(Color.white.opacity(0.05))
    }
    .strong {
      FontWeight(.semibold)
      ForegroundColor(Color.textSecondary)
    }
    .emphasis {
      FontStyle(.italic)
    }
    .link {
      ForegroundColor(Color(red: 0.5, green: 0.65, blue: 0.85))
    }
    .heading1 { configuration in
      configuration.label
        .markdownTextStyle {
          FontSize(TypeScale.subhead)
          FontWeight(.semibold)
          ForegroundColor(Color.textSecondary)
        }
        .markdownMargin(top: 10, bottom: 5)
    }
    .heading2 { configuration in
      configuration.label
        .markdownTextStyle {
          FontSize(TypeScale.body)
          FontWeight(.semibold)
          ForegroundColor(Color.textSecondary)
        }
        .markdownMargin(top: 8, bottom: 4)
    }
    .heading3 { configuration in
      configuration.label
        .markdownTextStyle {
          FontSize(TypeScale.code)
          FontWeight(.semibold)
          ForegroundColor(Color.textSecondary)
        }
        .markdownMargin(top: 6, bottom: 3)
    }
    .paragraph { configuration in
      configuration.label
        .markdownMargin(top: 0, bottom: 6)
    }
    .listItem { configuration in
      configuration.label
        .markdownMargin(top: 1, bottom: 1)
    }
    .blockquote { configuration in
      HStack(spacing: 0) {
        RoundedRectangle(cornerRadius: 1)
          .fill(Color.textTertiary.opacity(0.5))
          .frame(width: 2)
        configuration.label
          .markdownTextStyle {
            ForegroundColor(Color.textSecondary.opacity(0.8))
            FontStyle(.italic)
            FontSize(TypeScale.code)
          }
          .padding(.leading, 10)
      }
      .markdownMargin(top: 5, bottom: 5)
    }
    .codeBlock { configuration in
      ScrollView(.horizontal, showsIndicators: false) {
        Text(configuration.content)
          .font(.system(size: TypeScale.caption, design: .monospaced))
          .foregroundStyle(Color.textSecondary)
          .padding(8)
      }
      .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 4))
      .markdownMargin(top: 6, bottom: 6)
    }

  static let orbitDock = Theme()
    // Editorial terminal rhythm: readable body + explicit markdown hierarchy.
    .text {
      ForegroundColor(Color.textPrimary)
      FontSize(TypeScale.chatBody)
    }
    // Inline code gets a dedicated tier so commands stand out in prose.
    .code {
      FontFamilyVariant(.monospaced)
      FontSize(TypeScale.chatCode)
      ForegroundColor(Color(red: 0.95, green: 0.68, blue: 0.45))
      BackgroundColor(Color.white.opacity(0.09))
    }
    .strong {
      FontWeight(.semibold)
      ForegroundColor(Color.textPrimary)
    }
    .emphasis {
      FontStyle(.italic)
    }
    .link {
      ForegroundColor(Color(red: 0.5, green: 0.72, blue: 0.95))
      UnderlineStyle(.single)
    }
    // H1 — display tier (serif) for major section breaks.
    .heading1 { configuration in
      configuration.label
        .markdownTextStyle {
          FontSize(TypeScale.chatHeading1)
          FontWeight(.bold)
          ForegroundColor(Color.textPrimary)
        }
        .font(.system(size: TypeScale.chatHeading1, weight: .bold, design: .serif))
        .markdownMargin(top: 22, bottom: 10)
    }
    // H2 — strong sectional heading.
    .heading2 { configuration in
      configuration.label
        .markdownTextStyle {
          FontSize(TypeScale.chatHeading2)
          FontWeight(.semibold)
          ForegroundColor(Color.textPrimary.opacity(0.95))
        }
        .font(.system(size: TypeScale.chatHeading2, weight: .semibold, design: .serif))
        .markdownMargin(top: 18, bottom: 8)
    }
    // H3 — compact subsection marker.
    .heading3 { configuration in
      configuration.label
        .markdownTextStyle {
          FontSize(TypeScale.chatHeading3)
          FontWeight(.semibold)
          ForegroundColor(Color.textSecondary)
        }
        .markdownMargin(top: 14, bottom: 6)
    }
    // Paragraph rhythm tuned for long assistant replies.
    .paragraph { configuration in
      configuration.label
        .markdownMargin(top: 0, bottom: 10)
    }
    // Lists should read like real steps, not wall-of-text bullets.
    .listItem { configuration in
      configuration.label
        .markdownMargin(top: 2, bottom: 4)
    }
    .taskListMarker { configuration in
      TaskListCheckbox(isCompleted: configuration.isCompleted)
    }
    // Blockquotes read as side-notes with a cool accent spine.
    .blockquote { configuration in
      HStack(spacing: 0) {
        RoundedRectangle(cornerRadius: 2)
          .fill(Color.accentMuted.opacity(0.9))
          .frame(width: 3)
        configuration.label
          .markdownTextStyle {
            ForegroundColor(Color.textSecondary.opacity(0.9))
            FontStyle(.italic)
            FontSize(TypeScale.reading)
          }
          .padding(.leading, 14)
      }
      .markdownMargin(top: 10, bottom: 10)
    }
    .thematicBreak {
      HorizontalDivider()
        .markdownMargin(top: 14, bottom: 14)
    }
    .codeBlock { configuration in
      CodeBlockView(
        language: configuration.language,
        code: configuration.content
      )
      .markdownMargin(top: 12, bottom: 12)
    }
    .table { configuration in
      configuration.label
        .markdownTableBackgroundStyle(.alternatingRows(Color.white.opacity(0.02), Color.white.opacity(0.05)))
        .markdownTableBorderStyle(.init(color: Color.white.opacity(0.12)))
        .markdownMargin(top: 12, bottom: 12)
    }
    .tableCell { configuration in
      configuration.label
        .markdownTextStyle {
          FontSize(TypeScale.chatBody)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
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

  private let collapseThreshold = 15 // Lines before collapsing
  private let collapsedLineCount = 8 // Lines to show when collapsed

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
      // Header
      header

      Divider()
        .opacity(0.3)

      // Code content with line numbers
      codeContent

      // Expand/collapse button for long code
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

  // MARK: - Subviews

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

      // Line count
      Text("\(lines.count) lines")
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.tertiary)

      // Copy button
      Button {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
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
        // Line numbers
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

        // Highlighted code
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(displayLines.enumerated()), id: \.offset) { _, line in
            Text(SyntaxHighlighter.highlightLine(line, language: normalizedLanguage))
              .font(.system(size: 12.5, design: .monospaced))
              .frame(height: 18, alignment: .leading)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .textSelection(.enabled)
        .padding(.horizontal, 14)
      }
      .padding(.vertical, 10)
    }
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
