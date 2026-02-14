//
//  InlineCommentThread.swift
//  OrbitDock
//
//  Renders review comments inline below the annotated diff line.
//  Matches the DiffHunkView gutter grid: [3px purple bar][72px gutter][1px sep][body]
//

import SwiftUI

struct InlineCommentThread: View {
  let comments: [ServerReviewComment]
  let onResolve: (ServerReviewComment) -> Void

  private let gutterBorder = Color.white.opacity(0.06)

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(comments) { comment in
        commentCard(comment)
      }
    }
  }

  private func commentCard(_ comment: ServerReviewComment) -> some View {
    let isResolved = comment.status == .resolved

    return HStack(alignment: .top, spacing: 0) {
      // Purple edge bar
      Rectangle()
        .fill(Color.statusQuestion)
        .frame(width: 3)

      // Gutter zone with bubble icon
      HStack {
        Spacer()
        Image(systemName: "text.bubble.fill")
          .font(.system(size: 9))
          .foregroundStyle(Color.statusQuestion.opacity(isResolved ? 0.3 : 0.6))
        Spacer()
      }
      .frame(width: 72)

      // Separator
      Rectangle()
        .fill(gutterBorder)
        .frame(width: 1)

      // Comment body
      VStack(alignment: .leading, spacing: 4) {
        // Header: tag + timestamp + resolve toggle
        HStack(spacing: 6) {
          if let tag = comment.tag {
            Text(tag.rawValue)
              .font(.system(size: 9, weight: .semibold))
              .foregroundStyle(Color.statusQuestion)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Color.statusQuestion.opacity(0.12), in: Capsule())
          }

          Text(relativeTime(comment.createdAt))
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.tertiary)

          Spacer()

          Button {
            onResolve(comment)
          } label: {
            Image(systemName: isResolved ? "checkmark.circle.fill" : "checkmark.circle")
              .font(.system(size: 12))
              .foregroundStyle(isResolved ? Color.statusReady : Color.white.opacity(0.3))
          }
          .buttonStyle(.plain)
          .help(isResolved ? "Unresolve" : "Resolve")
        }

        // Body text
        Text(comment.body)
          .font(.system(size: 12, design: .monospaced))
          .foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)

        if let lineEnd = comment.lineEnd, lineEnd != comment.lineStart {
          Text("Lines \(comment.lineStart)–\(lineEnd)")
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.quaternary)
        }
      }
      .padding(8)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.statusQuestion.opacity(0.04))
    .opacity(isResolved ? 0.5 : 1.0)
    .overlay(alignment: .top) {
      Rectangle()
        .fill(Color.statusQuestion.opacity(0.15))
        .frame(height: 1)
    }
  }

  private func relativeTime(_ isoString: String) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = formatter.date(from: isoString) else {
      // Try without fractional seconds
      formatter.formatOptions = [.withInternetDateTime]
      guard let date = formatter.date(from: isoString) else { return isoString }
      return formatRelative(date)
    }
    return formatRelative(date)
  }

  private func formatRelative(_ date: Date) -> String {
    let elapsed = -date.timeIntervalSinceNow
    if elapsed < 60 { return "just now" }
    if elapsed < 3600 { return "\(Int(elapsed / 60))m ago" }
    if elapsed < 86400 { return "\(Int(elapsed / 3600))h ago" }
    return "\(Int(elapsed / 86400))d ago"
  }
}
