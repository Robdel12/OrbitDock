//
//  ApprovalDiffPreview.swift
//  OrbitDock
//
//  Read-only compact diff renderer for patch approval cards.
//  Simpler than DiffHunkView — no cursor, comments, selection, or drag.
//

import SwiftUI

struct ApprovalDiffPreview: View {
  let diffString: String

  @State private var isExpanded = true

  private var model: DiffModel {
    DiffModel.parse(unifiedDiff: diffString)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Toggle header
      Button {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
          isExpanded.toggle()
        }
      } label: {
        HStack(spacing: Spacing.sm) {
          Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Color.textTertiary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))

          Text("Diff Preview")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textSecondary)

          Spacer()

          // Aggregate stats
          let stats = aggregateStats
          HStack(spacing: Spacing.xs) {
            Text("+\(stats.additions)")
              .foregroundStyle(Color.diffAddedAccent)
            Text("−\(stats.deletions)")
              .foregroundStyle(Color.diffRemovedAccent)
          }
          .font(.system(size: TypeScale.caption, weight: .semibold, design: .monospaced))
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if isExpanded {
        ScrollView(.vertical, showsIndicators: true) {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(model.files) { file in
              fileSection(file)
            }
          }
        }
        .frame(maxHeight: 300)
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .background(Color.backgroundPrimary)
    .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
  }

  // MARK: - File Section

  private func fileSection(_ file: FileDiff) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      // File header
      HStack(spacing: Spacing.sm) {
        Text(file.newPath.components(separatedBy: "/").last ?? file.newPath)
          .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.textPrimary)
          .lineLimit(1)

        Spacer()

        let stats = file.stats
        HStack(spacing: Spacing.xs) {
          Text("+\(stats.additions)")
            .foregroundStyle(Color.diffAddedAccent)
          Text("−\(stats.deletions)")
            .foregroundStyle(Color.diffRemovedAccent)
        }
        .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.xs)
      .background(Color.backgroundTertiary.opacity(0.5))

      // Hunks
      ForEach(file.hunks) { hunk in
        ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
          diffLineRow(line)
        }
      }
    }
  }

  // MARK: - Diff Line

  private func diffLineRow(_ line: DiffLine) -> some View {
    HStack(spacing: 0) {
      // Edge bar
      Rectangle()
        .fill(edgeColor(for: line.type))
        .frame(width: EdgeBar.width)

      // Line numbers (gutter)
      HStack(spacing: 0) {
        Text(line.oldLineNum.map { String($0) } ?? "")
          .frame(width: 32, alignment: .trailing)
        Text(line.newLineNum.map { String($0) } ?? "")
          .frame(width: 32, alignment: .trailing)
      }
      .font(.system(size: TypeScale.caption, design: .monospaced))
      .foregroundStyle(Color.textQuaternary)
      .padding(.trailing, Spacing.xs)

      // Content
      Text(line.content)
        .font(.system(size: TypeScale.caption, design: .monospaced))
        .foregroundStyle(contentColor(for: line.type))
        .lineLimit(1)

      Spacer(minLength: 0)
    }
    .background(lineBackground(for: line.type))
  }

  // MARK: - Colors

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

  // MARK: - Stats

  private var aggregateStats: (additions: Int, deletions: Int) {
    let adds = model.files.reduce(0) { $0 + $1.stats.additions }
    let dels = model.files.reduce(0) { $0 + $1.stats.deletions }
    return (adds, dels)
  }
}

#Preview {
  ApprovalDiffPreview(diffString: """
  --- a/src/main.swift
  +++ b/src/main.swift
  @@ -1,5 +1,7 @@
   import Foundation
  +import SwiftUI

   func main() {
  -    print("hello")
  +    print("hello world")
  +    print("goodbye")
   }
  """)
  .frame(width: 500)
  .background(Color.backgroundPrimary)
}
