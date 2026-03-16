//
//  CompactContextExpandedView.swift
//  OrbitDock
//
//  Token savings visualization for context compaction.
//

import SwiftUI

struct CompactContextExpandedView: View {
  let content: ServerRowContent

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      // Header
      HStack(spacing: Spacing.sm) {
        Image(systemName: "arrow.triangle.2.circlepath")
          .font(.system(size: IconScale.sm))
          .foregroundStyle(Color.accent)
        Text("Context Compacted")
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.accent)
      }

      // Summary with savings highlight
      if let input = content.inputDisplay, !input.isEmpty {
        Text(input)
          .font(.system(size: TypeScale.body))
          .foregroundStyle(Color.textSecondary)
      }

      // Savings visualization
      if let output = content.outputDisplay, !output.isEmpty {
        VStack(alignment: .leading, spacing: Spacing.sm) {
          Text("Savings")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textTertiary)

          Text(output)
            .font(.system(size: TypeScale.code, design: .monospaced))
            .foregroundStyle(Color.feedbackPositive)
            .padding(Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
              Color.feedbackPositive.opacity(OpacityTier.tint),
              in: RoundedRectangle(cornerRadius: Radius.sm)
            )
        }
      }
    }
  }
}
