import SwiftUI

/// Compact diff renderer for approval cards.
struct ControlDeckApprovalDiffPreview: View {
  let diffString: String

  @State private var isExpanded = true

  private var model: DiffModel {
    DiffModel.parse(unifiedDiff: diffString)
  }

  private var stats: (additions: Int, deletions: Int) {
    let adds = model.files.reduce(0) { $0 + $1.stats.additions }
    let dels = model.files.reduce(0) { $0 + $1.stats.deletions }
    return (adds, dels)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Collapsible header
      Button {
        isExpanded.toggle()
      } label: {
        HStack(spacing: Spacing.xs) {
          Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(Color.textQuaternary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))

          Text("Changes")
            .font(.system(size: TypeScale.mini, weight: .semibold))
            .foregroundStyle(Color.textTertiary)

          Spacer()

          HStack(spacing: Spacing.xxs) {
            Text("+\(stats.additions)")
              .foregroundStyle(Color.diffAddedAccent)
            Text("−\(stats.deletions)")
              .foregroundStyle(Color.diffRemovedAccent)
          }
          .font(.system(size: TypeScale.mini, weight: .bold, design: .monospaced))
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      // Diff content
      if isExpanded {
        ScrollView(.vertical, showsIndicators: false) {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(model.files) { file in
              fileSection(file)
            }
          }
        }
        .frame(maxHeight: 160)
      }
    }
    .background(Color.backgroundTertiary.opacity(0.5))
    .clipShape(RoundedRectangle(cornerRadius: Radius.md))
  }

  private func fileSection(_ file: FileDiff) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      // Only show file header if multiple files
      if model.files.count > 1 {
        HStack(spacing: Spacing.xs) {
          Text(compactPath(file.newPath))
            .font(.system(size: TypeScale.mini, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.textSecondary)
            .lineLimit(1)

          Spacer()

          HStack(spacing: Spacing.xxs) {
            Text("+\(file.stats.additions)")
              .foregroundStyle(Color.diffAddedAccent)
            Text("−\(file.stats.deletions)")
              .foregroundStyle(Color.diffRemovedAccent)
          }
          .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xxs)
        .background(Color.backgroundTertiary)
      }

      ForEach(file.hunks) { hunk in
        ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
          diffLineRow(line)
        }
      }
    }
  }

  private func diffLineRow(_ line: DiffLine) -> some View {
    HStack(spacing: 0) {
      // Edge indicator
      Rectangle()
        .fill(edgeColor(for: line.type))
        .frame(width: 2)

      // Single line number (new line for adds, old for removes)
      Text(lineNumber(for: line))
        .font(.system(size: TypeScale.micro, design: .monospaced))
        .foregroundStyle(Color.textQuaternary)
        .frame(width: 24, alignment: .trailing)
        .padding(.trailing, Spacing.xxs)

      // Content
      Text(line.content)
        .font(.system(size: TypeScale.caption, design: .monospaced))
        .foregroundStyle(contentColor(for: line.type))
        .lineLimit(1)

      Spacer(minLength: 0)
    }
    .padding(.leading, Spacing.xs)
    .background(lineBackground(for: line.type))
  }

  private func lineNumber(for line: DiffLine) -> String {
    switch line.type {
      case .added: line.newLineNum.map { String($0) } ?? ""
      case .removed: line.oldLineNum.map { String($0) } ?? ""
      case .context: line.newLineNum.map { String($0) } ?? ""
    }
  }

  private func edgeColor(for type: DiffLineType) -> Color {
    switch type {
      case .added: Color.diffAddedEdge
      case .removed: Color.diffRemovedEdge
      case .context: .clear
    }
  }

  private func contentColor(for type: DiffLineType) -> Color {
    switch type {
      case .added: Color.diffAddedAccent
      case .removed: Color.diffRemovedAccent
      case .context: Color.textTertiary
    }
  }

  private func lineBackground(for type: DiffLineType) -> Color {
    switch type {
      case .added: Color.diffAddedBg
      case .removed: Color.diffRemovedBg
      case .context: .clear
    }
  }

  /// Shows parent/filename for disambiguation (e.g., "Views/MyFile.swift")
  private func compactPath(_ path: String) -> String {
    let components = path.components(separatedBy: "/")
    guard components.count >= 2 else { return path }
    let parent = components[components.count - 2]
    let fileName = components[components.count - 1]
    return "\(parent)/\(fileName)"
  }
}
