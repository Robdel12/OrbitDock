//
//  FileListRow.swift
//  OrbitDock
//
//  Individual file entry in the file list navigator.
//

import SwiftUI

struct FileListRow: View {
  let fileDiff: FileDiff
  let isSelected: Bool
  var commentCount: Int = 0
  var isAddressed: Bool = false       // Model modified this file after review
  var isReviewPending: Bool = false   // File was reviewed, waiting for response

  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 8) {
      // Change-type indicator — vertical bar instead of dot
      RoundedRectangle(cornerRadius: 1)
        .fill(changeTypeColor)
        .frame(width: EdgeBar.width, height: 24)
        .opacity(isSelected ? 1 : 0.6)

      // Filename + parent path
      VStack(alignment: .leading, spacing: 2) {
        Text(fileName)
          .font(.system(size: TypeScale.body, weight: isSelected ? .semibold : .medium))
          .foregroundStyle(isSelected ? .primary : (isHovered ? .primary : .secondary))
          .lineLimit(1)

        if !parentPath.isEmpty {
          Text(parentPath)
            .font(.system(size: TypeScale.micro, design: .monospaced))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
      }

      Spacer(minLength: 0)

      // Review status indicator
      if isAddressed {
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 10))
          .foregroundStyle(Color.accent)
      } else if isReviewPending {
        Image(systemName: "clock")
          .font(.system(size: 9))
          .foregroundStyle(Color.statusQuestion.opacity(0.6))
      }

      // Comment count badge
      if commentCount > 0 {
        Text("\(commentCount)")
          .font(.system(size: TypeScale.micro, weight: .bold))
          .foregroundStyle(Color.statusQuestion)
          .padding(.horizontal, 5)
          .padding(.vertical, 1)
          .background(Color.statusQuestion.opacity(OpacityTier.light), in: Capsule())
      }

      // Stats — compact
      HStack(spacing: 3) {
        if fileDiff.stats.additions > 0 {
          Text("+\(fileDiff.stats.additions)")
            .foregroundStyle(Color.diffAddedAccent.opacity(0.8))
        }
        if fileDiff.stats.deletions > 0 {
          Text("\u{2212}\(fileDiff.stats.deletions)")
            .foregroundStyle(Color.diffRemovedAccent.opacity(0.8))
        }
      }
      .font(.system(size: TypeScale.micro, weight: .semibold, design: .monospaced))
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 7)
    .background(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .fill(isSelected ? Color.accent.opacity(OpacityTier.light) : (isHovered ? Color.surfaceHover : Color.clear))
        .padding(.horizontal, 4)
    )
    .overlay(alignment: .leading) {
      if isSelected {
        Rectangle()
          .fill(Color.accent)
          .frame(width: EdgeBar.width)
          .clipShape(RoundedRectangle(cornerRadius: 1))
      }
    }
    .contentShape(Rectangle())
    .onHover { hovering in
      isHovered = hovering
    }
  }

  // MARK: - Helpers

  private var fileName: String {
    let path = fileDiff.newPath.isEmpty ? fileDiff.oldPath : fileDiff.newPath
    return path.components(separatedBy: "/").last ?? path
  }

  private var parentPath: String {
    let path = fileDiff.newPath.isEmpty ? fileDiff.oldPath : fileDiff.newPath
    let components = path.components(separatedBy: "/")
    if components.count > 1 {
      return components.dropLast().joined(separator: "/")
    }
    return ""
  }

  private var changeTypeColor: Color {
    switch fileDiff.changeType {
    case .added: Color.diffAddedAccent
    case .deleted: Color.diffRemovedAccent
    case .renamed: Color.accent
    case .modified: Color.accent
    }
  }
}
