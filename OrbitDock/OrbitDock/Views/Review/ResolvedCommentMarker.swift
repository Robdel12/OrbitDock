//
//  ResolvedCommentMarker.swift
//  OrbitDock
//
//  Inline marker for resolved review comments. Collapsed shows a single-line
//  summary; expanded reveals the full comment. Pixel-aligned with DiffHunkView:
//  [3px edge][32px old num][8px dot][32px new num][1px sep][20px prefix][content]
//

import SwiftUI

struct ResolvedCommentMarker: View {
  let comments: [ServerReviewComment]
  let onReopen: (ServerReviewComment) -> Void
  var startExpanded: Bool = false

  @State private var isExpanded = false

  private let gutterBg = Color.white.opacity(0.015)
  private let gutterBorder = Color.white.opacity(0.06)

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      collapsedBar
      if isExpanded {
        ForEach(comments) { comment in
          expandedCard(comment)
        }
      }
    }
    .onAppear {
      if startExpanded { isExpanded = true }
    }
    .onChange(of: startExpanded) { _, newVal in
      isExpanded = newVal
    }
  }

  // MARK: - Collapsed Bar

  private var collapsedBar: some View {
    HStack(spacing: 0) {
      // Edge bar — dimmed purple
      Rectangle()
        .fill(Color.statusQuestion.opacity(0.3))
        .frame(width: EdgeBar.width)

      // Gutter — matches diff line number columns
      HStack(spacing: 0) {
        Spacer()
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: TypeScale.micro))
          .foregroundStyle(Color.statusQuestion.opacity(0.4))
        Spacer()
      }
      .frame(width: 72)
      .background(gutterBg)

      // Separator
      Rectangle()
        .fill(gutterBorder)
        .frame(width: 1)

      // Prefix zone — aligns with diff prefix column
      Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
        .font(.system(size: 7, weight: .bold))
        .foregroundStyle(Color.statusQuestion.opacity(0.5))
        .frame(width: 20)

      // Content — readable, not invisible
      HStack(spacing: 5) {
        Text("\(comments.count) resolved")
          .font(.system(size: TypeScale.body, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.statusQuestion.opacity(0.6))

        if !isExpanded, let first = comments.first {
          Text(first.body.prefix(60))
            .font(.system(size: TypeScale.body, design: .monospaced))
            .foregroundStyle(.primary.opacity(0.25))
            .lineLimit(1)
        }

        Spacer(minLength: 0)
      }
      .padding(.trailing, 12)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(minHeight: 22)
    .background(Color.statusQuestion.opacity(OpacityTier.tint))
    .contentShape(Rectangle())
    .onTapGesture {
      withAnimation(.spring(response: 0.2, dampingFraction: 0.85)) {
        isExpanded.toggle()
      }
    }
    .overlay(alignment: .top) {
      Rectangle()
        .fill(Color.statusQuestion.opacity(OpacityTier.subtle))
        .frame(height: 1)
    }
  }

  // MARK: - Expanded Card

  private func expandedCard(_ comment: ServerReviewComment) -> some View {
    HStack(spacing: 0) {
      // Edge bar
      Rectangle()
        .fill(Color.statusQuestion.opacity(OpacityTier.medium))
        .frame(width: EdgeBar.width)

      // Gutter — blank with checkmark
      HStack(spacing: 0) {
        Spacer()
        Image(systemName: "checkmark")
          .font(.system(size: 7, weight: .bold))
          .foregroundStyle(Color.statusQuestion.opacity(0.3))
        Spacer()
      }
      .frame(width: 72)
      .background(gutterBg)

      // Separator
      Rectangle()
        .fill(gutterBorder)
        .frame(width: 1)

      // Left quote bar — 20px zone (prefix alignment) used as a visual quote mark
      Rectangle()
        .fill(Color.statusQuestion.opacity(OpacityTier.medium))
        .frame(width: EdgeBar.width)
        .padding(.leading, 9)
        .padding(.trailing, 9)

      // Comment content — compact single-line when possible
      VStack(alignment: .leading, spacing: 2) {
        Text(comment.body)
          .font(.system(size: TypeScale.body, design: .monospaced))
          .foregroundStyle(.primary.opacity(0.4))
          .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 6) {
          if let tag = comment.tag {
            Text(tag.rawValue)
              .font(.system(size: 8, weight: .semibold))
              .foregroundStyle(Color.statusQuestion.opacity(0.5))
              .padding(.horizontal, 4)
              .padding(.vertical, 1)
              .background(Color.statusQuestion.opacity(OpacityTier.subtle), in: Capsule())
          }

          Spacer()

          Button {
            onReopen(comment)
          } label: {
            Text("Reopen")
              .font(.system(size: TypeScale.micro, weight: .medium))
              .foregroundStyle(Color.statusQuestion.opacity(0.5))
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Color.statusQuestion.opacity(OpacityTier.subtle), in: Capsule())
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.vertical, 5)
      .padding(.trailing, 12)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.statusQuestion.opacity(OpacityTier.tint))
    .overlay(alignment: .top) {
      Rectangle()
        .fill(Color.statusQuestion.opacity(OpacityTier.subtle))
        .frame(height: 1)
    }
  }
}
