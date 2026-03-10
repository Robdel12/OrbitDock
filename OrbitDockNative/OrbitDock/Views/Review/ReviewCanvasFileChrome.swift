import SwiftUI

extension ReviewCanvas {
  // MARK: - File Section Header

  func fileSectionHeader(file: FileDiff, fileIndex: Int, isCursor: Bool) -> some View {
    let isCollapsed = collapsedFiles.contains(file.id)

    return HStack(spacing: 0) {
      Rectangle()
        .fill(isCursor ? Color.accent : Color.clear)
        .frame(width: EdgeBar.width)

      Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
        .font(.system(size: TypeScale.micro, weight: .semibold))
        .foregroundStyle(isCursor ? Color.accent : Color.white.opacity(0.25))
        .frame(width: Spacing.xl)

      ZStack {
        Circle()
          .fill(changeTypeColor(file.changeType).opacity(OpacityTier.light))
          .frame(width: 22, height: 22)
        Image(systemName: fileIcon(file.changeType))
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(changeTypeColor(file.changeType))
      }
      .padding(.trailing, Spacing.sm)

      filePathLabel(file.newPath)
        .padding(.trailing, Spacing.sm)

      HStack(spacing: Spacing.sm_) {
        if file.stats.additions > 0 {
          HStack(spacing: Spacing.xxs) {
            Text("+")
              .foregroundStyle(Color.diffAddedAccent.opacity(0.7))
            Text("\(file.stats.additions)")
              .foregroundStyle(Color.diffAddedAccent)
          }
        }
        if file.stats.deletions > 0 {
          HStack(spacing: Spacing.xxs) {
            Text("\u{2212}")
              .foregroundStyle(Color.diffRemovedAccent.opacity(0.7))
            Text("\(file.stats.deletions)")
              .foregroundStyle(Color.diffRemovedAccent)
          }
        }
      }
      .font(.system(size: TypeScale.caption, weight: .bold, design: .monospaced))

      if let addressed = fileAddressedStatus(for: file.newPath) {
        HStack(spacing: Spacing.gap) {
          Image(systemName: addressed ? "checkmark" : "clock")
            .font(.system(size: 8, weight: .bold))
          Text(addressed ? "Updated" : "In review")
            .font(.system(size: TypeScale.micro, weight: .semibold))
        }
        .foregroundStyle(addressed ? Color.accent : Color.statusQuestion)
        .padding(.horizontal, Spacing.sm_)
        .padding(.vertical, Spacing.xxs)
        .background(
          (addressed ? Color.accent : Color.statusQuestion).opacity(OpacityTier.light),
          in: Capsule()
        )
      }

      Spacer(minLength: Spacing.lg)

      if isCollapsed {
        Text("\(file.hunks.count) hunk\(file.hunks.count == 1 ? "" : "s")")
          .font(.system(size: TypeScale.micro, weight: .medium))
          .foregroundStyle(Color.textTertiary)
          .padding(.trailing, Spacing.sm)
      }
    }
    .padding(.vertical, Spacing.sm)
    .padding(.trailing, Spacing.sm)
    .background(isCursor ? Color.accent.opacity(OpacityTier.light) : Color.backgroundSecondary)
    .contentShape(Rectangle())
  }

  func filePathLabel(_ path: String) -> some View {
    let components = path.components(separatedBy: "/")
    let fileName = components.last ?? path
    let dirPath = components.count > 1 ? components.dropLast().joined(separator: "/") + "/" : ""

    return HStack(spacing: 0) {
      if !dirPath.isEmpty {
        Text(dirPath)
          .font(.system(size: TypeScale.body, weight: .regular, design: .monospaced))
          .foregroundStyle(Color.textTertiary)
      }
      Text(fileName)
        .font(.system(size: TypeScale.body, weight: .semibold, design: .monospaced))
        .foregroundStyle(.primary)
    }
    .lineLimit(1)
  }

  func changeTypeColor(_ type: FileChangeType) -> Color {
    switch type {
      case .added: Color.diffAddedAccent
      case .deleted: Color.diffRemovedAccent
      case .renamed, .modified: Color.accent
    }
  }

  func fileIcon(_ type: FileChangeType) -> String {
    switch type {
      case .added: "plus"
      case .deleted: "minus"
      case .renamed: "arrow.right"
      case .modified: "pencil"
    }
  }
}
