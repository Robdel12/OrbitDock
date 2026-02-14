//
//  CommentComposerView.swift
//  OrbitDock
//
//  Inline comment composer below an annotated diff line.
//  Matches the DiffHunkView gutter grid: [3px purple bar][72px gutter][1px sep][content]
//

import SwiftUI

struct CommentComposerView: View {
  @Binding var commentBody: String
  @Binding var tag: ServerReviewCommentTag?
  let onSubmit: () -> Void
  let onCancel: () -> Void

  @FocusState private var isTextFocused: Bool

  private let gutterBorder = Color.white.opacity(0.06)

  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      // Purple edge bar
      Rectangle()
        .fill(Color.statusQuestion)
        .frame(width: 3)

      // Empty gutter zone
      Color.clear
        .frame(width: 72)

      // Separator
      Rectangle()
        .fill(gutterBorder)
        .frame(width: 1)

      // Composer content
      VStack(alignment: .leading, spacing: 8) {
        // Tag picker
        HStack(spacing: 6) {
          ForEach(ServerReviewCommentTag.allCases, id: \.self) { t in
            tagCapsule(t, isSelected: tag == t)
          }
        }

        // Text editor
        TextEditor(text: $commentBody)
          .font(.system(size: 12, design: .monospaced))
          .scrollContentBackground(.hidden)
          .focused($isTextFocused)
          .frame(minHeight: 48, maxHeight: 120)
          .padding(6)
          .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .fill(Color.backgroundPrimary.opacity(0.6))
          )
          .overlay(alignment: .topLeading) {
            if commentBody.isEmpty {
              Text("Add a comment...")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 14)
                .allowsHitTesting(false)
            }
          }

        // Action row
        HStack(spacing: 8) {
          Spacer()

          Button(action: onCancel) {
            Text("Cancel")
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(.secondary)
              .padding(.horizontal, 12)
              .padding(.vertical, 6)
          }
          .buttonStyle(.plain)

          Button {
            onSubmit()
          } label: {
            Text("Comment")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(.white)
              .padding(.horizontal, 14)
              .padding(.vertical, 6)
              .background(
                commentBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  ? Color.statusQuestion.opacity(0.4)
                  : Color.statusQuestion,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
              )
          }
          .buttonStyle(.plain)
          .disabled(commentBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      .padding(10)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.backgroundTertiary)
    .overlay(alignment: .top) {
      Rectangle()
        .fill(Color.statusQuestion.opacity(0.3))
        .frame(height: 1)
    }
    .onAppear {
      isTextFocused = true
    }
    .onKeyPress(keys: [.return]) { keyPress in
      guard keyPress.modifiers.contains(.command) else { return .ignored }
      guard !commentBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .ignored }
      onSubmit()
      return .handled
    }
    .onKeyPress(keys: [.escape]) { _ in
      onCancel()
      return .handled
    }
  }

  private func tagCapsule(_ t: ServerReviewCommentTag, isSelected: Bool) -> some View {
    Button {
      tag = isSelected ? nil : t
    } label: {
      Text(t.rawValue)
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(isSelected ? .white : Color.statusQuestion)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
          isSelected
            ? Color.statusQuestion
            : Color.statusQuestion.opacity(0.12),
          in: Capsule()
        )
        .overlay(
          Capsule()
            .strokeBorder(Color.statusQuestion.opacity(isSelected ? 0 : 0.3), lineWidth: 1)
        )
    }
    .buttonStyle(.plain)
  }
}

extension ServerReviewCommentTag: CaseIterable {
  public static var allCases: [ServerReviewCommentTag] {
    [.clarity, .scope, .risk, .nit]
  }
}
