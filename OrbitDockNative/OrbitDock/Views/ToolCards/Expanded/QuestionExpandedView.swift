//
//  QuestionExpandedView.swift
//  OrbitDock
//
//  Question/response expanded view with visual separation.
//

import SwiftUI

struct QuestionExpandedView: View {
  let content: ServerRowContent
  let toolRow: ServerConversationToolRow

  private var hasResponse: Bool {
    if let output = content.outputDisplay, !output.isEmpty { return true }
    return false
  }

  private var isCompleted: Bool {
    toolRow.status == .completed
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      // Question bubble
      if let input = content.inputDisplay, !input.isEmpty {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          HStack(spacing: Spacing.xs) {
            Image(systemName: "questionmark.bubble")
              .font(.system(size: IconScale.sm))
              .foregroundStyle(Color.toolQuestion)
            Text("Question")
              .font(.system(size: TypeScale.caption, weight: .semibold))
              .foregroundStyle(Color.textTertiary)
            Spacer()
            // Answered/pending badge
            if hasResponse {
              HStack(spacing: Spacing.xxs) {
                Image(systemName: "checkmark.circle.fill")
                  .font(.system(size: 8))
                Text("Answered")
                  .font(.system(size: TypeScale.mini, weight: .semibold))
              }
              .foregroundStyle(Color.feedbackPositive)
            } else {
              HStack(spacing: Spacing.xxs) {
                Circle()
                  .fill(Color.feedbackCaution)
                  .frame(width: 5, height: 5)
                Text("Pending")
                  .font(.system(size: TypeScale.mini, weight: .semibold))
              }
              .foregroundStyle(Color.feedbackCaution)
            }
          }
          Text(input)
            .font(.system(size: TypeScale.body))
            .foregroundStyle(Color.textSecondary)
            .padding(Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.toolQuestion.opacity(OpacityTier.tint), in: RoundedRectangle(cornerRadius: Radius.sm))
            .overlay(alignment: .leading) {
              RoundedRectangle(cornerRadius: Radius.sm)
                .fill(Color.toolQuestion)
                .frame(width: 3)
            }
        }
      }

      // Connecting line between Q and A
      if hasResponse {
        HStack {
          Spacer().frame(width: Spacing.lg)
          Rectangle()
            .fill(Color.textQuaternary.opacity(0.2))
            .frame(width: 1, height: Spacing.md)
        }
      }

      // Response
      if let output = content.outputDisplay, !output.isEmpty {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          HStack(spacing: Spacing.xs) {
            Image(systemName: "text.bubble")
              .font(.system(size: IconScale.sm))
              .foregroundStyle(Color.statusReply)
            Text("Response")
              .font(.system(size: TypeScale.caption, weight: .semibold))
              .foregroundStyle(Color.textTertiary)
          }
          Text(output)
            .font(.system(size: TypeScale.body))
            .foregroundStyle(Color.textSecondary)
            .padding(Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.statusReply.opacity(OpacityTier.tint), in: RoundedRectangle(cornerRadius: Radius.sm))
        }
      } else if isCompleted {
        // Completed but no output recorded
        HStack(spacing: Spacing.sm) {
          Image(systemName: "minus.circle")
            .font(.system(size: IconScale.sm))
            .foregroundStyle(Color.textQuaternary)
          Text("No response recorded")
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textQuaternary)
        }
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.sm))
      } else {
        // Pending state placeholder
        HStack(spacing: Spacing.sm) {
          ProgressView()
            .controlSize(.small)
          Text("Awaiting response...")
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textQuaternary)
        }
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.sm))
      }
    }
  }
}
