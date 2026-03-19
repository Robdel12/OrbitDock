//
//  ThinkingRowView.swift
//  OrbitDock
//
//  SwiftUI view for reasoning/thinking traces — always shown inline.
//

import SwiftUI

struct ThinkingRowView: View {
  let content: String
  let isStreaming: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text("Reasoning")
        .font(.system(size: TypeScale.chatLabel, weight: .semibold))
        .foregroundStyle(Color.textTertiary)

      if !content.isEmpty {
        MarkdownContentView(content: content, style: .thinking)
          .opacity(0.7)
      }
    }
    .padding(.vertical, Spacing.md)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
