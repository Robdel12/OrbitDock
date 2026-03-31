import SwiftUI

/// Read-only compact diff renderer for tool approval cards.
struct ControlDeckApprovalDiffPreview: View {
  let diffString: String

  @State private var isExpanded = true

  private var model: DiffModel {
    DiffModel.parse(unifiedDiff: diffString)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        isExpanded.toggle()
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
      }
    }
    .background(Color.backgroundPrimary)
    .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
  }

  private func fileSection(_ file: FileDiff) -> some View {
    VStack(alignment: .leading, spacing: 0) {
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

      ForEach(file.hunks) { hunk in
        ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
          diffLineRow(line)
        }
      }
    }
  }

  private func diffLineRow(_ line: DiffLine) -> some View {
    HStack(spacing: 0) {
      Rectangle()
        .fill(edgeColor(for: line.type))
        .frame(width: EdgeBar.width)

      HStack(spacing: 0) {
        Text(line.oldLineNum.map { String($0) } ?? "")
          .frame(width: 32, alignment: .trailing)
        Text(line.newLineNum.map { String($0) } ?? "")
          .frame(width: 32, alignment: .trailing)
      }
      .font(.system(size: TypeScale.caption, design: .monospaced))
      .foregroundStyle(Color.textQuaternary)
      .padding(.trailing, Spacing.xs)

      Text(line.content)
        .font(.system(size: TypeScale.caption, design: .monospaced))
        .foregroundStyle(contentColor(for: line.type))
        .lineLimit(1)

      Spacer(minLength: 0)
    }
    .background(lineBackground(for: line.type))
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

  private var aggregateStats: (additions: Int, deletions: Int) {
    let adds = model.files.reduce(0) { $0 + $1.stats.additions }
    let dels = model.files.reduce(0) { $0 + $1.stats.deletions }
    return (adds, dels)
  }
}
