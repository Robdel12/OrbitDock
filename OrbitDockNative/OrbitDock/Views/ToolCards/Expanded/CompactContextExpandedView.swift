//
//  CompactContextExpandedView.swift
//  OrbitDock
//
//  Minimal system event card for context compaction.
//

import SwiftUI

struct CompactContextExpandedView: View {
  let content: ServerRowContent

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack(spacing: Spacing.sm) {
        Image(systemName: "arrow.triangle.2.circlepath")
          .font(.system(size: IconScale.sm))
          .foregroundStyle(Color.accent)
        Text("Context Compacted")
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.accent)
      }

      if let input = content.inputDisplay, !input.isEmpty {
        Text(input)
          .font(.system(size: TypeScale.body))
          .foregroundStyle(Color.textSecondary)
      }

      if let output = content.outputDisplay, !output.isEmpty {
        Text(output)
          .font(.system(size: TypeScale.code, design: .monospaced))
          .foregroundStyle(Color.textTertiary)
          .padding(Spacing.sm)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.sm))
      }
    }
  }
}
