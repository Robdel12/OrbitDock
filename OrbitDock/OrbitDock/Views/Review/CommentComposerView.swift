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
  var fileName: String?
  var lineLabel: String?
  let onSubmit: () -> Void
  let onCancel: () -> Void

  @FocusState private var isTextFocused: Bool

  private let gutterBorder = Color.white.opacity(0.06)

  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      // Purple edge bar
      Rectangle()
        .fill(Color.statusQuestion)
        .frame(width: EdgeBar.width)

      // Empty gutter zone
      Color.clear
        .frame(width: 72)

      // Separator
      Rectangle()
        .fill(gutterBorder)
        .frame(width: 1)

      // Composer content
      VStack(alignment: .leading, spacing: Spacing.sm) {
        // Line metadata + tag picker
        HStack(spacing: Spacing.sm) {
          if let lineLabel {
            HStack(spacing: Spacing.xs) {
              Image(systemName: "text.line.first.and.arrowtriangle.forward")
                .font(.system(size: 8, weight: .medium))
              Text(lineLabel)
                .font(.system(size: TypeScale.caption, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(Color.statusQuestion.opacity(0.9))

            if let fileName {
              Text("in")
                .font(.system(size: TypeScale.micro))
                .foregroundStyle(Color.textQuaternary)
              Text(fileName)
                .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.textTertiary)
            }
          }

          Spacer()

          // Tag picker
          HStack(spacing: Spacing.sm_) {
            ForEach(ServerReviewCommentTag.allCases, id: \.self) { t in
              tagCapsule(t, isSelected: tag == t)
            }
          }
        }

        // Text editor
        TextEditor(text: $commentBody)
          .font(.system(size: TypeScale.code, design: .monospaced))
          .scrollContentBackground(.hidden)
          .focused($isTextFocused)
          .frame(minHeight: 48, maxHeight: 96)
          .padding(Spacing.sm_)
          .background(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
              .fill(Color.backgroundPrimary.opacity(0.6))
          )
          .overlay(alignment: .topLeading) {
            if commentBody.isEmpty {
              Text("Add a comment...")
                .font(.system(size: TypeScale.code, design: .monospaced))
                .foregroundStyle(Color.textTertiary)
                .padding(.horizontal, Spacing.md_)
                .padding(.vertical, Spacing.lg_)
                .allowsHitTesting(false)
            }
          }

        // Action row
        HStack(spacing: Spacing.sm) {
          Spacer()

          Button(action: onCancel) {
            Text("Cancel")
              .font(.system(size: TypeScale.body, weight: .medium))
              .foregroundStyle(.secondary)
              .padding(.horizontal, Spacing.md)
              .padding(.vertical, Spacing.sm_)
          }
          .buttonStyle(.plain)

          Button {
            onSubmit()
          } label: {
            Text("Comment")
              .font(.system(size: TypeScale.body, weight: .semibold))
              .foregroundStyle(.white)
              .padding(.horizontal, Spacing.lg_)
              .padding(.vertical, Spacing.sm_)
              .background(
                commentBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  ? Color.statusQuestion.opacity(0.4)
                  : Color.statusQuestion,
                in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
              )
          }
          .buttonStyle(.plain)
          .disabled(commentBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      .padding(Spacing.sm)
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
        .font(.system(size: TypeScale.caption, weight: .medium))
        .foregroundStyle(isSelected ? .white : Color.statusQuestion)
        .padding(.horizontal, Spacing.md_)
        .padding(.vertical, Spacing.xs)
        .background(
          isSelected
            ? Color.statusQuestion
            : Color.statusQuestion.opacity(OpacityTier.light),
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
