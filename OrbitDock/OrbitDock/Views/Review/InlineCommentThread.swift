//
//  InlineCommentThread.swift
//  OrbitDock
//
//  Renders open review comments inline below the annotated diff line.
//  Pixel-aligned with DiffHunkView gutter grid:
//  [3px edge][72px gutter][1px sep][20px prefix zone][comment content]
//

import SwiftUI

struct InlineCommentThread: View {
  let comments: [ServerReviewComment]
  let selectedIds: Set<String>
  let onResolve: (ServerReviewComment) -> Void
  let onToggleSelection: (ServerReviewComment) -> Void

  private let gutterBg = Color.white.opacity(0.015)
  private let gutterBorder = Color.white.opacity(0.06)

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(comments) { comment in
        commentCard(comment)
      }
    }
  }

  private func commentCard(_ comment: ServerReviewComment) -> some View {
    let isSelected = selectedIds.contains(comment.id)

    return HStack(alignment: .top, spacing: 0) {
      // Purple edge bar — brighter when selected
      Rectangle()
        .fill(isSelected ? Color.accent : Color.statusQuestion)
        .frame(width: EdgeBar.width)

      // Gutter zone with selection toggle — matches diff line number width
      Button {
        onToggleSelection(comment)
      } label: {
        HStack {
          Spacer()
          Image(systemName: isSelected ? "checkmark.circle.fill" : "text.bubble.fill")
            .font(.system(size: TypeScale.micro))
            .foregroundStyle(isSelected ? Color.accent : Color.statusQuestion.opacity(0.6))
          Spacer()
        }
      }
      .buttonStyle(.plain)
      .frame(width: 72)
      .background(gutterBg)

      // Separator
      Rectangle()
        .fill(gutterBorder)
        .frame(width: 1)

      // Left quote bar — occupies the 20px prefix zone
      Rectangle()
        .fill(Color.statusQuestion.opacity(0.5))
        .frame(width: 2)
        .padding(.leading, 9)
        .padding(.trailing, 9)

      // Comment body — now aligns with code content
      VStack(alignment: .leading, spacing: 4) {
        // Header: tag + timestamp + resolve toggle
        HStack(spacing: 6) {
          if let tag = comment.tag {
            Text(tag.rawValue)
              .font(.system(size: TypeScale.micro, weight: .semibold))
              .foregroundStyle(Color.statusQuestion)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Color.statusQuestion.opacity(OpacityTier.light), in: Capsule())
          }

          Text(relativeTime(comment.createdAt))
            .font(.system(size: TypeScale.micro, design: .monospaced))
            .foregroundStyle(.tertiary)

          Spacer()

          Button {
            onResolve(comment)
          } label: {
            Image(systemName: "checkmark.circle")
              .font(.system(size: TypeScale.code))
              .foregroundStyle(Color.white.opacity(0.3))
          }
          .buttonStyle(.plain)
          .help("Resolve")
        }

        // Body text
        Text(comment.body)
          .font(.system(size: TypeScale.code, design: .monospaced))
          .foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)

        if let lineEnd = comment.lineEnd, lineEnd != comment.lineStart {
          Text("Lines \(comment.lineStart)–\(lineEnd)")
            .font(.system(size: TypeScale.micro, design: .monospaced))
            .foregroundStyle(.quaternary)
        }
      }
      .padding(.vertical, 6)
      .padding(.trailing, 12)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.statusQuestion.opacity(OpacityTier.tint))
    .overlay(alignment: .top) {
      Rectangle()
        .fill(Color.statusQuestion.opacity(OpacityTier.light))
        .frame(height: 1)
    }
  }

  private func relativeTime(_ isoString: String) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = formatter.date(from: isoString) else {
      formatter.formatOptions = [.withInternetDateTime]
      guard let date = formatter.date(from: isoString) else { return isoString }
      return formatRelative(date)
    }
    return formatRelative(date)
  }

  private func formatRelative(_ date: Date) -> String {
    let elapsed = -date.timeIntervalSinceNow
    if elapsed < 60 { return "just now" }
    if elapsed < 3_600 { return "\(Int(elapsed / 60))m ago" }
    if elapsed < 86_400 { return "\(Int(elapsed / 3_600))h ago" }
    return "\(Int(elapsed / 86_400))d ago"
  }
}
