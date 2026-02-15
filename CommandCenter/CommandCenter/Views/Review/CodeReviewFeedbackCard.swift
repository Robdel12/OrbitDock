//
//  CodeReviewFeedbackCard.swift
//  OrbitDock
//
//  Special UI card for review feedback messages sent to the model.
//  Parses the structured "## Code Review Feedback" markdown format
//  into a visually rich card with file sections, code blocks, and comments.
//

import SwiftUI

struct CodeReviewFeedbackCard: View {
  let content: String
  let timestamp: Date
  var onNavigateToFile: ((String, Int) -> Void)? = nil  // (filePath, lineNumber)

  private var sections: [ReviewFeedbackSection] {
    parseReviewFeedback(content)
  }

  private var totalComments: Int {
    sections.reduce(0) { $0 + $1.comments.count }
  }

  @State private var collapsedFiles: Set<String> = []
  @State private var expandedFiles: Set<String> = []  // Files showing all comments (past initial cap)

  private let initialCommentCap = 3

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      cardHeader

      Rectangle()
        .fill(Color.statusQuestion.opacity(0.3))
        .frame(height: 1)

      fileSections
    }
    .background(Color.statusQuestion.opacity(OpacityTier.tint))
    .clipShape(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
        .strokeBorder(Color.statusQuestion.opacity(OpacityTier.medium), lineWidth: 1)
    )
  }

  // MARK: - Card Header

  private var cardHeader: some View {
    HStack(spacing: 8) {
      Image(systemName: "text.bubble.fill")
        .font(.system(size: TypeScale.body, weight: .medium))
        .foregroundStyle(Color.statusQuestion)

      Text("Code Review")
        .font(.system(size: TypeScale.code, weight: .semibold))
        .foregroundStyle(Color.statusQuestion)

      Text("\(totalComments)")
        .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
        .foregroundStyle(Color.statusQuestion)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.statusQuestion.opacity(OpacityTier.light), in: Capsule())

      Spacer()

      if sections.count > 1 {
        HStack(spacing: 3) {
          Image(systemName: "doc.on.doc")
            .font(.system(size: 8, weight: .medium))
          Text("\(sections.count) files")
            .font(.system(size: TypeScale.micro, weight: .medium))
        }
        .foregroundStyle(.quaternary)
      }

      Text(formatTime(timestamp))
        .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
        .foregroundStyle(.quaternary)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(Color.statusQuestion.opacity(OpacityTier.subtle))
  }

  // MARK: - File Sections

  private var fileSections: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(sections.enumerated()), id: \.offset) { idx, section in
        if idx > 0 {
          Rectangle()
            .fill(Color.statusQuestion.opacity(0.1))
            .frame(height: 1)
        }
        FileSectionView(
          section: section,
          isCollapsed: collapsedFiles.contains(section.filePath),
          isExpanded: expandedFiles.contains(section.filePath),
          initialCap: initialCommentCap,
          onToggleCollapse: {
            if collapsedFiles.contains(section.filePath) {
              collapsedFiles.remove(section.filePath)
            } else {
              collapsedFiles.insert(section.filePath)
            }
          },
          onShowAll: {
            expandedFiles.insert(section.filePath)
          },
          onNavigateToFile: onNavigateToFile
        )
      }
    }
  }

  // MARK: - Helpers

  private func formatTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
  }
}

// MARK: - File Section View (extracted for type checker)

private struct FileSectionView: View {
  let section: ReviewFeedbackSection
  let isCollapsed: Bool
  let isExpanded: Bool
  let initialCap: Int
  let onToggleCollapse: () -> Void
  let onShowAll: () -> Void
  var onNavigateToFile: ((String, Int) -> Void)?

  private var visibleComments: [ReviewFeedbackComment] {
    if isExpanded || section.comments.count <= initialCap {
      return section.comments
    }
    return Array(section.comments.prefix(initialCap))
  }

  private var hiddenCount: Int {
    guard !isExpanded else { return 0 }
    return max(0, section.comments.count - initialCap)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      fileSectionHeader

      if !isCollapsed {
        ForEach(Array(visibleComments.enumerated()), id: \.offset) { idx, comment in
          if idx > 0 {
            Rectangle()
              .fill(Color.white.opacity(OpacityTier.tint))
              .frame(height: 1)
              .padding(.leading, 12)
          }
          CommentEntryView(
            comment: comment,
            filePath: section.filePath,
            onNavigateToFile: onNavigateToFile
          )
        }

        if hiddenCount > 0 {
          showMoreButton
        }
      }
    }
  }

  private var fileSectionHeader: some View {
    Button(action: onToggleCollapse) {
      HStack(spacing: 6) {
        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
          .font(.system(size: 7, weight: .bold))
          .foregroundStyle(Color.statusQuestion.opacity(0.4))
          .frame(width: 10)

        Image(systemName: "doc.text")
          .font(.system(size: TypeScale.micro, weight: .medium))
          .foregroundStyle(Color.statusQuestion.opacity(0.5))

        filePathLabel(section.filePath)

        Spacer()

        Text("\(section.comments.count)")
          .font(.system(size: TypeScale.micro, weight: .semibold, design: .monospaced))
          .foregroundStyle(.quaternary)
          .padding(.horizontal, 5)
          .padding(.vertical, 1)
          .background(Color.white.opacity(OpacityTier.tint), in: Capsule())
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .background(Color.statusQuestion.opacity(OpacityTier.tint))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private var showMoreButton: some View {
    Button(action: onShowAll) {
      HStack(spacing: 4) {
        Image(systemName: "ellipsis")
          .font(.system(size: 8, weight: .bold))
        Text("\(hiddenCount) more comment\(hiddenCount == 1 ? "" : "s")")
          .font(.system(size: TypeScale.caption, weight: .medium))
      }
      .foregroundStyle(Color.statusQuestion.opacity(0.7))
      .frame(maxWidth: .infinity)
      .padding(.vertical, 6)
      .background(Color.statusQuestion.opacity(OpacityTier.tint))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func filePathLabel(_ path: String) -> some View {
    let components = path.components(separatedBy: "/")
    let fileName = components.last ?? path
    let dirPath = components.count > 1 ? components.dropLast().joined(separator: "/") + "/" : ""

    return HStack(spacing: 0) {
      if !dirPath.isEmpty {
        Text(dirPath)
          .font(.system(size: TypeScale.body, weight: .regular, design: .monospaced))
          .foregroundStyle(.tertiary)
      }
      Text(fileName)
        .font(.system(size: TypeScale.body, weight: .semibold, design: .monospaced))
        .foregroundStyle(.primary.opacity(0.9))
    }
    .lineLimit(1)
  }
}

// MARK: - Comment Entry View (extracted for type checker)

private struct CommentEntryView: View {
  let comment: ReviewFeedbackComment
  let filePath: String
  var onNavigateToFile: ((String, Int) -> Void)?

  @State private var isHovered = false

  private var lineNumber: Int? {
    // Parse "Line 42" or "Lines 3–5" → first line number
    let ref = comment.lineRef
    let digits = ref.components(separatedBy: CharacterSet.decimalDigits.inverted).first(where: { !$0.isEmpty })
    return digits.flatMap { Int($0) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      commentLineRefRow

      if let code = comment.code {
        DiffCodeBlock(code: code, language: comment.language)
      }

      commentBodyQuote
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(isHovered && onNavigateToFile != nil ? Color.statusQuestion.opacity(0.06) : Color.clear)
    .contentShape(Rectangle())
    .onHover { hovering in
      isHovered = hovering
    }
    .onTapGesture {
      if let line = lineNumber {
        onNavigateToFile?(filePath, line)
      }
    }
  }

  private var commentLineRefRow: some View {
    HStack(spacing: 6) {
      HStack(spacing: 4) {
        Image(systemName: "text.line.first.and.arrowtriangle.forward")
          .font(.system(size: 8, weight: .medium))
        Text(comment.lineRef)
          .font(.system(size: TypeScale.caption, weight: .semibold, design: .monospaced))
      }
      .foregroundStyle(Color.statusQuestion.opacity(0.9))

      if let tag = comment.tag {
        TagBadgeView(tag: tag)
      }

      Spacer()

      // Deep link hint on hover
      if isHovered, onNavigateToFile != nil {
        HStack(spacing: 3) {
          Image(systemName: "arrow.turn.up.right")
            .font(.system(size: 7, weight: .bold))
          Text("Jump to diff")
            .font(.system(size: TypeScale.micro, weight: .medium))
        }
        .foregroundStyle(Color.statusQuestion.opacity(0.5))
        .transition(.opacity)
      }
    }
  }

  private var commentBodyQuote: some View {
    HStack(alignment: .top, spacing: 8) {
      Rectangle()
        .fill(Color.statusQuestion.opacity(0.4))
        .frame(width: EdgeBar.width)

      Text(comment.body)
        .font(.system(size: TypeScale.code))
        .foregroundStyle(.primary.opacity(0.9))
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

// MARK: - Tag Badge View

private struct TagBadgeView: View {
  let tag: String

  private var color: Color {
    switch tag.lowercased() {
    case "risk": Color.diffRemovedAccent
    case "nit": Color.white.opacity(0.5)
    case "scope": Color.accent
    case "clarity": Color.statusQuestion
    default: Color.statusQuestion
    }
  }

  var body: some View {
    Text(tag)
      .font(.system(size: TypeScale.micro, weight: .semibold))
      .foregroundStyle(color)
      .padding(.horizontal, 7)
      .padding(.vertical, 2)
      .background(color.opacity(OpacityTier.light), in: Capsule())
      .overlay(Capsule().strokeBorder(color.opacity(OpacityTier.medium), lineWidth: 0.5))
  }
}

// MARK: - Diff Code Block

private struct DiffCodeBlock: View {
  let code: String
  let language: String?

  private var codeLines: [String] {
    code.components(separatedBy: "\n")
  }

  var body: some View {
    ScrollView(.vertical, showsIndicators: false) {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(codeLines.enumerated()), id: \.offset) { _, codeLine in
          DiffCodeLineView(codeLine: codeLine, language: language)
        }
      }
    }
    .frame(maxHeight: 120)
    .padding(.vertical, 4)
    .background(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .fill(Color.backgroundPrimary.opacity(0.5))
    )
    .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
    )
  }
}

// MARK: - Diff Code Line

private struct DiffCodeLineView: View {
  let codeLine: String
  let language: String?

  private enum CodeLineType { case added, removed, context }

  private var lineType: CodeLineType {
    if codeLine.hasPrefix("+") { return .added }
    if codeLine.hasPrefix("-") { return .removed }
    return .context
  }

  private var edgeColor: Color {
    switch lineType {
    case .added: Color.diffAddedEdge
    case .removed: Color.diffRemovedEdge
    case .context: .clear
    }
  }

  private var prefixColor: Color {
    switch lineType {
    case .added: Color.diffAddedAccent
    case .removed: Color.diffRemovedAccent
    case .context: .clear
    }
  }

  private var bgColor: Color {
    switch lineType {
    case .added: Color.diffAddedBg
    case .removed: Color.diffRemovedBg
    case .context: .clear
    }
  }

  private var highlightedContent: AttributedString {
    let content: String
    if codeLine.hasPrefix("+") || codeLine.hasPrefix("-") || codeLine.hasPrefix(" ") {
      content = String(codeLine.dropFirst(1))
    } else {
      content = codeLine
    }
    return SyntaxHighlighter.highlightLine(content, language: language)
  }

  var body: some View {
    HStack(spacing: 0) {
      Rectangle()
        .fill(edgeColor)
        .frame(width: EdgeBar.width)

      Text(lineType == .context ? " " : String(codeLine.prefix(1)))
        .font(.system(size: TypeScale.body, weight: .semibold, design: .monospaced))
        .foregroundStyle(prefixColor)
        .frame(width: 14, alignment: .center)

      Text(highlightedContent)
        .font(.system(size: TypeScale.body, design: .monospaced))
        .lineLimit(1)
    }
    .padding(.vertical, 1)
    .background(bgColor)
  }
}

// MARK: - Parsed Review Feedback Types

private struct ReviewFeedbackSection {
  let filePath: String
  var comments: [ReviewFeedbackComment]
}

private struct ReviewFeedbackComment {
  let lineRef: String
  let tag: String?
  let code: String?
  let language: String?
  let body: String
}

// MARK: - Parser

/// Parse the structured "## Code Review Feedback" markdown into sections.
private func parseReviewFeedback(_ content: String) -> [ReviewFeedbackSection] {
  let lines = content.components(separatedBy: "\n")
  var sections: [ReviewFeedbackSection] = []
  var currentFile: String?
  var currentComment: (lineRef: String, tag: String?, code: String?, language: String?, body: String)?
  var inCodeBlock = false
  var codeLines: [String] = []
  var codeLang: String?

  func flushComment() {
    guard let comment = currentComment, let file = currentFile else { return }
    let entry = ReviewFeedbackComment(
      lineRef: comment.lineRef,
      tag: comment.tag,
      code: comment.code,
      language: comment.language,
      body: comment.body
    )
    if let idx = sections.firstIndex(where: { $0.filePath == file }) {
      sections[idx].comments.append(entry)
    }
    currentComment = nil
  }

  for line in lines {
    let trimmed = line.trimmingCharacters(in: .whitespaces)

    // Skip the top-level header
    if trimmed.hasPrefix("## Code Review Feedback") { continue }
    if trimmed.isEmpty && currentComment == nil { continue }

    // File header: ### path/to/file.ext
    if trimmed.hasPrefix("### ") {
      flushComment()
      let filePath = String(trimmed.dropFirst(4))
      currentFile = filePath
      sections.append(ReviewFeedbackSection(filePath: filePath, comments: []))
      continue
    }

    // Code block fences
    if trimmed.hasPrefix("```") {
      if inCodeBlock {
        // Close code block
        inCodeBlock = false
        if currentComment != nil {
          currentComment?.code = codeLines.joined(separator: "\n")
          currentComment?.language = codeLang
        }
        codeLines = []
        codeLang = nil
      } else {
        // Open code block
        inCodeBlock = true
        codeLang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        if codeLang?.isEmpty == true { codeLang = nil }
      }
      continue
    }

    if inCodeBlock {
      codeLines.append(line)
      continue
    }

    // Bold line ref: **Line 42** or **Lines 3–5** [tag]:
    if trimmed.hasPrefix("**") {
      flushComment()
      let parsed = parseLineRef(trimmed)
      currentComment = (lineRef: parsed.lineRef, tag: parsed.tag, code: nil, language: nil, body: "")
      continue
    }

    // Quote body: > comment text
    if trimmed.hasPrefix("> ") {
      let quoteText = String(trimmed.dropFirst(2))
      if currentComment != nil {
        if currentComment!.body.isEmpty {
          currentComment?.body = quoteText
        } else {
          currentComment?.body += "\n" + quoteText
        }
      }
      continue
    }
  }

  flushComment()
  return sections
}

/// Parse a line like: **Line 42** [nit]:  or  **Lines 3–5** [clarity]:
private func parseLineRef(_ line: String) -> (lineRef: String, tag: String?) {
  // Extract between ** **
  guard let firstStar = line.range(of: "**"),
        let secondStar = line.range(of: "**", range: firstStar.upperBound..<line.endIndex)
  else {
    return (lineRef: line, tag: nil)
  }

  let lineRef = String(line[firstStar.upperBound..<secondStar.lowerBound])

  // Extract [tag] if present
  let rest = String(line[secondStar.upperBound...])
  var tag: String?
  if let openBracket = rest.range(of: "["),
     let closeBracket = rest.range(of: "]", range: openBracket.upperBound..<rest.endIndex) {
    tag = String(rest[openBracket.upperBound..<closeBracket.lowerBound])
  }

  return (lineRef: lineRef, tag: tag)
}
