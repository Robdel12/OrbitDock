//
//  GlobExpandedView.swift
//  OrbitDock
//
//  File tree visualization for glob results.
//  Features: pattern highlighting, collapsible directory tree, file count badges.
//

import SwiftUI

struct GlobExpandedView: View {
  let content: ServerRowContent

  @State private var allExpanded = true

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      if let input = content.inputDisplay, !input.isEmpty {
        patternDisplay(input)
      }

      if let output = content.outputDisplay, !output.isEmpty {
        let files = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        let tree = FileTreeBuilder.buildTree(from: files)

        FileTypeDistributionBar(files: files)

        VStack(alignment: .leading, spacing: Spacing.xs) {
          HStack {
            Text("Files")
              .font(.system(size: TypeScale.caption, weight: .semibold))
              .foregroundStyle(Color.textTertiary)
            Spacer()
            Button(action: { allExpanded.toggle() }) {
              Text(allExpanded ? "Collapse all" : "Expand all")
                .font(.system(size: TypeScale.mini, weight: .medium))
                .foregroundStyle(Color.accent)
            }
            .buttonStyle(.plain)
            Text("\(files.count) matches")
              .font(.system(size: TypeScale.mini, design: .monospaced))
              .foregroundStyle(Color.textQuaternary)
          }

          VStack(alignment: .leading, spacing: 0) {
            if tree.isEmpty {
              // Flat list fallback
              ForEach(Array(files.enumerated()), id: \.offset) { _, file in
                fileRow(name: file, isDirectory: false, depth: 0)
              }
            } else {
              ForEach(tree) { node in
                FileTreeNodeView(node: node, depth: 0, defaultExpanded: allExpanded)
              }
              .id(allExpanded)
            }
          }
          .padding(.vertical, Spacing.xs)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.sm))
        }
      }
    }
  }

  // MARK: - Pattern Display

  private func patternDisplay(_ pattern: String) -> some View {
    HStack(spacing: Spacing.xs) {
      Image(systemName: "folder.badge.gearshape")
        .font(.system(size: IconScale.sm))
        .foregroundStyle(Color.toolSearch)
      highlightedPattern(pattern)
    }
  }

  @ViewBuilder
  private func highlightedPattern(_ pattern: String) -> some View {
    // Highlight wildcard segments in accent, literals in primary
    let parts = splitPatternSegments(pattern)
    HStack(spacing: 0) {
      ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
        Text(part.text)
          .font(.system(size: TypeScale.code, design: .monospaced))
          .foregroundStyle(part.isWildcard ? Color.accent : Color.textPrimary)
      }
    }
  }

  private struct PatternSegment {
    let text: String
    let isWildcard: Bool
  }

  private func splitPatternSegments(_ pattern: String) -> [PatternSegment] {
    var segments: [PatternSegment] = []
    var current = ""
    var i = pattern.startIndex

    while i < pattern.endIndex {
      let char = pattern[i]
      if char == "*" || char == "?" || char == "[" {
        if !current.isEmpty {
          segments.append(PatternSegment(text: current, isWildcard: false))
          current = ""
        }
        var wildcard = String(char)
        let next = pattern.index(after: i)
        if char == "*", next < pattern.endIndex, pattern[next] == "*" {
          wildcard = "**"
          i = next
        }
        segments.append(PatternSegment(text: wildcard, isWildcard: true))
      } else {
        current.append(char)
      }
      i = pattern.index(after: i)
    }
    if !current.isEmpty {
      segments.append(PatternSegment(text: current, isWildcard: false))
    }
    return segments
  }

  // MARK: - File Row

  private func fileRow(name: String, isDirectory: Bool, depth: Int) -> some View {
    HStack(spacing: Spacing.sm_) {
      Image(systemName: isDirectory ? "folder.fill" : "doc.text")
        .font(.system(size: 8))
        .foregroundStyle(isDirectory ? Color.feedbackCaution.opacity(0.6) : Color.toolSearch.opacity(0.5))
      Text(name)
        .font(.system(size: TypeScale.code, design: .monospaced))
        .foregroundStyle(Color.textSecondary)
    }
    .padding(.leading, Spacing.sm + CGFloat(depth) * 16)
    .padding(.trailing, Spacing.sm)
    .padding(.vertical, Spacing.xxs)
  }
}

// MARK: - Tree Node View

private struct FileTreeNodeView: View {
  let node: FileTreeNode
  let depth: Int
  var defaultExpanded: Bool = true

  @State private var isExpanded: Bool

  init(node: FileTreeNode, depth: Int, defaultExpanded: Bool = true) {
    self.node = node
    self.depth = depth
    self.defaultExpanded = defaultExpanded
    self._isExpanded = State(initialValue: defaultExpanded)
  }

  var body: some View {
    if node.isDirectory {
      directoryNode
    } else {
      fileNode
    }
  }

  private var directoryNode: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button(action: { withAnimation(Motion.snappy) { isExpanded.toggle() } }) {
        HStack(spacing: Spacing.sm_) {
          // Indentation guide
          if depth > 0 {
            ForEach(0..<depth, id: \.self) { _ in
              Rectangle()
                .fill(Color.textQuaternary.opacity(0.12))
                .frame(width: 1)
                .padding(.horizontal, 7)
            }
          }

          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(Color.textQuaternary)

          Image(systemName: "folder.fill")
            .font(.system(size: 8))
            .foregroundStyle(Color.feedbackCaution.opacity(0.6))

          Text(node.name)
            .font(.system(size: TypeScale.code, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.textSecondary)

          Text("\(node.fileCount)")
            .font(.system(size: TypeScale.mini, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 1)
            .background(Color.textQuaternary.opacity(OpacityTier.tint), in: Capsule())
        }
        .padding(.leading, Spacing.sm)
        .padding(.trailing, Spacing.sm)
        .padding(.vertical, Spacing.xxs)
      }
      .buttonStyle(.plain)

      if isExpanded {
        ForEach(node.children) { child in
          FileTreeNodeView(node: child, depth: depth + 1, defaultExpanded: defaultExpanded)
        }
      }
    }
  }

  private var fileNode: some View {
    HStack(spacing: Spacing.sm_) {
      if depth > 0 {
        ForEach(0..<depth, id: \.self) { _ in
          Rectangle()
            .fill(Color.textQuaternary.opacity(0.12))
            .frame(width: 1)
            .padding(.horizontal, 7)
        }
      }

      Spacer().frame(width: 10) // align with chevron

      Image(systemName: fileIcon(for: node.name))
        .font(.system(size: 8))
        .foregroundStyle(fileColor(for: node.name))

      Text(node.name)
        .font(.system(size: TypeScale.code, design: .monospaced))
        .foregroundStyle(Color.textSecondary)
    }
    .padding(.leading, Spacing.sm)
    .padding(.trailing, Spacing.sm)
    .padding(.vertical, Spacing.xxs)
  }

  private func fileIcon(for name: String) -> String {
    let ext = name.components(separatedBy: ".").last?.lowercased() ?? ""
    switch ext {
    case "swift": return "swift"
    case "rs": return "gearshape"
    case "ts", "tsx", "js", "jsx": return "chevron.left.forwardslash.chevron.right"
    case "json", "yaml", "yml", "toml": return "doc.text"
    case "md": return "doc.richtext"
    case "png", "jpg", "svg": return "photo"
    default: return "doc.text"
    }
  }

  private func fileColor(for name: String) -> Color {
    let ext = name.components(separatedBy: ".").last?.lowercased() ?? ""
    switch ext {
    case "swift": return .langSwift
    case "rs": return .langRust
    case "ts", "tsx": return .langJavaScript
    case "js", "jsx": return .langJavaScript
    case "py": return .langPython
    case "go": return .langGo
    case "json": return .langJSON
    case "md": return .toolRead
    default: return .toolSearch.opacity(0.5)
    }
  }
}
