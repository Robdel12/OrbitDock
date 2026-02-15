//
//  FileListNavigator.swift
//  OrbitDock
//
//  Left pane of the review canvas: diff source selector, stats summary,
//  and file list with keyboard navigation.
//

import SwiftUI

struct FileListNavigator: View {
  let files: [FileDiff]
  let turnDiffs: [ServerTurnDiff]
  @Binding var selectedFileId: String?
  @Binding var selectedTurnDiffId: String?
  var commentCounts: [String: Int] = [:]  // filePath → count
  var addressedFiles: Set<String> = []     // Files modified after review
  var reviewPendingFiles: Set<String> = [] // Files reviewed but not yet modified
  var showResolvedComments: Binding<Bool>? = nil
  var hasResolvedComments: Bool = false

  var body: some View {
    VStack(spacing: 0) {
      // Diff source selector
      sourceSelector

      Divider()
        .foregroundStyle(Color.panelBorder)

      // Stats summary
      if !files.isEmpty {
        statsSummary
        Divider()
          .foregroundStyle(Color.panelBorder)
      }

      // File list
      if files.isEmpty {
        emptyFileList
      } else {
        fileList
      }
    }
    .frame(width: 220)
    .background(Color.backgroundSecondary)
  }

  // MARK: - Source Selector

  private var sourceSelector: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 4) {
        sourceButton(
          label: "All Changes",
          icon: "square.stack.3d.up",
          isSelected: selectedTurnDiffId == nil,
          isLive: true
        ) {
          selectedTurnDiffId = nil
        }

        ForEach(Array(turnDiffs.enumerated()), id: \.element.turnId) { index, turnDiff in
          sourceButton(
            label: "Edit \(index + 1)",
            icon: "number",
            isSelected: selectedTurnDiffId == turnDiff.turnId,
            isLive: false
          ) {
            selectedTurnDiffId = turnDiff.turnId
          }
        }
      }
      .padding(.horizontal, 8)
    }
    .padding(.vertical, 8)
  }

  private func sourceButton(label: String, icon: String, isSelected: Bool, isLive: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 4) {
        Image(systemName: icon)
          .font(.system(size: TypeScale.micro, weight: .medium))
        Text(label)
          .font(.system(size: TypeScale.caption, weight: isSelected ? .semibold : .medium))
      }
      .foregroundStyle(isSelected ? (isLive ? Color.accent : .primary) : .secondary)
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(
        isSelected
          ? (isLive ? Color.accent.opacity(OpacityTier.light) : Color.surfaceSelected)
          : Color.backgroundTertiary.opacity(0.5),
        in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
          .strokeBorder(isSelected ? Color.accent.opacity(OpacityTier.medium) : Color.clear, lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
  }

  // MARK: - Stats Summary

  private var statsSummary: some View {
    let totalAdds = files.reduce(0) { $0 + $1.stats.additions }
    let totalDels = files.reduce(0) { $0 + $1.stats.deletions }

    return HStack(spacing: 8) {
      Text("\(files.count) file\(files.count == 1 ? "" : "s")")
        .font(.system(size: TypeScale.caption, weight: .medium))
        .foregroundStyle(.secondary)

      if hasResolvedComments, let binding = showResolvedComments {
        Button {
          withAnimation(.spring(response: 0.2, dampingFraction: 0.85)) {
            binding.wrappedValue.toggle()
          }
        } label: {
          HStack(spacing: 3) {
            Image(systemName: binding.wrappedValue ? "eye.fill" : "eye.slash")
              .font(.system(size: 8, weight: .medium))
            Text("History")
              .font(.system(size: TypeScale.micro, weight: .medium))
          }
          .foregroundStyle(binding.wrappedValue ? Color.statusQuestion : Color.white.opacity(0.25))
        }
        .buttonStyle(.plain)
      }

      Spacer()

      // Mini bar chart — visual weight indicator
      HStack(spacing: 1) {
        if totalAdds > 0 {
          RoundedRectangle(cornerRadius: 1)
            .fill(Color.diffAddedEdge)
            .frame(width: barWidth(count: totalAdds, total: totalAdds + totalDels, maxWidth: 40), height: 6)
        }
        if totalDels > 0 {
          RoundedRectangle(cornerRadius: 1)
            .fill(Color.diffRemovedEdge)
            .frame(width: barWidth(count: totalDels, total: totalAdds + totalDels, maxWidth: 40), height: 6)
        }
      }

      HStack(spacing: 4) {
        Text("+\(totalAdds)")
          .foregroundStyle(Color.diffAddedAccent)
        Text("\u{2212}\(totalDels)")
          .foregroundStyle(Color.diffRemovedAccent)
      }
      .font(.system(size: TypeScale.caption, weight: .semibold, design: .monospaced))
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
  }

  private func barWidth(count: Int, total: Int, maxWidth: CGFloat) -> CGFloat {
    guard total > 0 else { return 0 }
    return max(3, CGFloat(count) / CGFloat(total) * maxWidth)
  }

  // MARK: - File List

  private var fileList: some View {
    ScrollViewReader { proxy in
      ScrollView(.vertical, showsIndicators: true) {
        VStack(spacing: 1) {
          ForEach(files) { file in
            FileListRow(
              fileDiff: file,
              isSelected: selectedFileId == file.id,
              commentCount: commentCounts[file.newPath] ?? 0,
              isAddressed: addressedFiles.contains(file.newPath),
              isReviewPending: reviewPendingFiles.contains(file.newPath)
            )
            .id(file.id)
            .onTapGesture {
              selectedFileId = file.id
            }
          }
        }
        .padding(.vertical, 4)
      }
      .onChange(of: selectedFileId) { _, newId in
        if let id = newId {
          withAnimation(.spring(response: 0.2, dampingFraction: 0.9)) {
            proxy.scrollTo(id, anchor: .center)
          }
        }
      }
    }
  }

  // MARK: - Empty State

  private var emptyFileList: some View {
    VStack(spacing: 8) {
      Image(systemName: "doc.text")
        .font(.system(size: 20, weight: .light))
        .foregroundStyle(.tertiary)

      Text("No files changed")
        .font(.system(size: TypeScale.body))
        .foregroundStyle(.tertiary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
