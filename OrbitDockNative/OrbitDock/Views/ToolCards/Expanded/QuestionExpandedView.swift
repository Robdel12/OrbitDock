//
//  QuestionExpandedView.swift
//  OrbitDock
//
//  Question/response expanded view with visual separation.
//

import SwiftUI

struct QuestionExpandedView: View {
  let content: ServerRowContent

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
      }
    }
  }
}
