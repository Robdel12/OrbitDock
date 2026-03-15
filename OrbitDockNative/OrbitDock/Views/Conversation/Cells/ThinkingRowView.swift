//
//  ThinkingRowView.swift
//  OrbitDock
//
//  SwiftUI view for reasoning/thinking traces with expand/collapse.
//

import SwiftUI

struct ThinkingRowView: View {
  let content: String
  let isStreaming: Bool
  let isExpanded: Bool
  let availableWidth: CGFloat

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      // Header row
      HStack(spacing: Spacing.sm_) {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
          .font(.system(size: IconScale.xs, weight: .semibold))
          .foregroundStyle(Color.textTertiary)

        Text("Reasoning")
          .font(.system(size: TypeScale.chatLabel, weight: .semibold))
          .foregroundStyle(Color.textTertiary)

        if isStreaming {
          ProgressView()
            .controlSize(.small)
        }

        Spacer()
      }
      .contentShape(Rectangle())

      if isExpanded, !content.isEmpty {
        MarkdownContentRepresentable(content: content, style: .thinking, availableWidth: availableWidth)
          .opacity(0.7)
      }
    }
    .padding(.horizontal, Spacing.xl)
    .padding(.vertical, Spacing.md)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
