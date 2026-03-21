import SwiftUI

extension ReviewCanvas {
  // MARK: - Compact File Strip

  func compactFileStrip(_ model: DiffModel) -> some View {
    let cursorFileIdx = currentFileIndex(model)

    return VStack(spacing: 0) {
      if !viewModel.turnDiffs.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: Spacing.xs) {
            compactSourceButton(
              label: "All Changes",
              icon: "square.stack.3d.up",
              isSelected: selectedTurnDiffId == nil
            ) {
              selectedTurnDiffId = nil
            }

            ForEach(Array(viewModel.turnDiffs.enumerated()), id: \.element.turnId) { index, turnDiff in
              compactSourceButton(
                label: "Edit \(index + 1)",
                icon: "number",
                isSelected: selectedTurnDiffId == turnDiff.turnId
              ) {
                selectedTurnDiffId = turnDiff.turnId
              }
            }
          }
          .padding(.horizontal, Spacing.sm)
          .padding(.vertical, Spacing.xs)
        }
        .background(Color.backgroundSecondary)

        Divider()
          .foregroundStyle(Color.panelBorder.opacity(0.5))
      }

      HStack(spacing: 0) {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: Spacing.xs) {
            ForEach(Array(model.files.enumerated()), id: \.element.id) { idx, file in
              fileChip(file, isSelected: idx == cursorFileIdx)
                .onTapGesture {
                  isFollowing = false
                  let targets = visibleTargets(model)
                  if let targetIdx = targets.firstIndex(of: .fileHeader(fileIndex: idx)) {
                    cursorIndex = targetIdx
                  }
                }
            }
          }
          .padding(.horizontal, Spacing.sm)
        }

        HStack(spacing: Spacing.sm_) {
          Divider()
            .frame(height: Spacing.lg)
            .foregroundStyle(Color.panelBorder)

          if hasResolvedComments {
            Button {
              withAnimation(Motion.snappy) {
                showResolvedComments.toggle()
              }
            } label: {
              HStack(spacing: Spacing.xs) {
                Image(systemName: showResolvedComments ? "eye.fill" : "eye.slash")
                  .font(.system(size: 8, weight: .medium))
                Text(showResolvedComments ? "History" : "History")
                  .font(.system(size: TypeScale.micro, weight: .medium))
              }
              .foregroundStyle(showResolvedComments ? Color.statusQuestion : Color.white.opacity(0.3))
            }
            .buttonStyle(.plain)

            Divider()
              .frame(height: Spacing.md)
              .foregroundStyle(Color.panelBorder)
          }

          if isSessionActive {
            Button {
              isFollowing.toggle()
              if isFollowing, let model = diffModel {
                let targets = visibleTargets(model)
                if let lastFile = targets.lastIndex(where: { $0.isFileHeader }) {
                  cursorIndex = lastFile
                }
              }
            } label: {
              HStack(spacing: Spacing.xs) {
                Circle()
                  .fill(isFollowing ? Color.accent : Color.white.opacity(0.2))
                  .frame(width: 5, height: 5)
                Text(isFollowing ? "Following" : "Paused")
                  .font(.system(size: TypeScale.micro, weight: .medium))
                  .foregroundStyle(isFollowing ? Color.accent : Color.white.opacity(0.3))
              }
            }
            .buttonStyle(.plain)
          }

          let totalAdds = model.files.reduce(0) { $0 + $1.stats.additions }
          let totalDels = model.files.reduce(0) { $0 + $1.stats.deletions }

          HStack(spacing: Spacing.xs) {
            Text("+\(totalAdds)")
              .foregroundStyle(Color.diffAddedAccent.opacity(0.8))
            Text("\u{2212}\(totalDels)")
              .foregroundStyle(Color.diffRemovedAccent.opacity(0.8))
          }
          .font(.system(size: TypeScale.micro, weight: .semibold, design: .monospaced))
        }
        .padding(.trailing, Spacing.sm)
      }
      .padding(.vertical, Spacing.sm)
    }
    .background(Color.backgroundSecondary)
  }

  func fileChip(_ file: FileDiff, isSelected: Bool) -> some View {
    let fileName = file.newPath.components(separatedBy: "/").last ?? file.newPath
    let changeColor = chipColor(file.changeType)
    let reviewStatus = fileAddressedStatus(for: file.newPath)

    return HStack(spacing: Spacing.xs) {
      if let addressed = reviewStatus {
        Circle()
          .fill(addressed ? Color.accent : Color.statusQuestion)
          .frame(width: 5, height: 5)
      } else {
        RoundedRectangle(cornerRadius: 1)
          .fill(changeColor)
          .frame(width: 2, height: Spacing.lg_)
      }

      Text(fileName)
        .font(.system(size: TypeScale.caption, weight: isSelected ? .semibold : .medium, design: .monospaced))
        .foregroundStyle(isSelected ? .primary : .secondary)
        .lineLimit(1)

      if file.stats.additions + file.stats.deletions > 0 {
        HStack(spacing: 0) {
          if file.stats.additions > 0 {
            RoundedRectangle(cornerRadius: 0.5)
              .fill(Color.diffAddedEdge)
              .frame(
                width: microBarWidth(count: file.stats.additions, total: file.stats.additions + file.stats.deletions),
                height: 3
              )
          }
          if file.stats.deletions > 0 {
            RoundedRectangle(cornerRadius: 0.5)
              .fill(Color.diffRemovedEdge)
              .frame(
                width: microBarWidth(count: file.stats.deletions, total: file.stats.additions + file.stats.deletions),
                height: 3
              )
          }
        }
      }
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.xs)
    .background(
      RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
        .fill(isSelected ? Color.accent.opacity(OpacityTier.light) : Color.backgroundTertiary.opacity(0.5))
    )
    .overlay(
      RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
        .strokeBorder(isSelected ? Color.accent.opacity(OpacityTier.medium) : Color.clear, lineWidth: 1)
    )
  }

  func microBarWidth(count: Int, total: Int) -> CGFloat {
    guard total > 0 else { return 0 }
    return max(3, CGFloat(count) / CGFloat(total) * 16)
  }

  func chipColor(_ type: FileChangeType) -> Color {
    switch type {
      case .added: Color.diffAddedAccent
      case .deleted: Color.diffRemovedAccent
      case .renamed, .modified: Color.accent
    }
  }

  func compactSourceButton(
    label: String,
    icon: String,
    isSelected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: Spacing.gap) {
        Image(systemName: icon)
          .font(.system(size: 8, weight: .medium))
        Text(label)
          .font(.system(size: TypeScale.micro, weight: isSelected ? .semibold : .medium))
      }
      .foregroundStyle(isSelected ? Color.accent : .secondary)
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.gap)
      .background(
        isSelected ? Color.accent.opacity(OpacityTier.light) : Color.backgroundTertiary.opacity(0.5),
        in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
          .strokeBorder(isSelected ? Color.accent.opacity(OpacityTier.medium) : Color.clear, lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
  }
}
