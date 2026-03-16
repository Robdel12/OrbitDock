//
//  HandoffExpandedView.swift
//  OrbitDock
//
//  Handoff expanded view with flow arrow, target badge, and transcript excerpt.
//

import SwiftUI

struct HandoffExpandedView: View {
  let content: ServerRowContent
  let toolRow: ServerConversationToolRow

  private var targetName: String? {
    // Extract from tool_display subtitle (server computes "target_name" as subtitle)
    toolRow.toolDisplay.subtitle
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      // Flow: Current -> Target
      HStack(spacing: Spacing.sm) {
        Text("Agent")
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.textTertiary)

        Image(systemName: "arrow.right")
          .font(.system(size: IconScale.xs))
          .foregroundStyle(Color.statusReply)

        if let target = targetName {
          Text(target)
            .font(.system(size: TypeScale.mini, weight: .bold))
            .foregroundStyle(Color.statusReply)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xxs)
            .background(Color.statusReply.opacity(OpacityTier.subtle), in: Capsule())
        }
      }

      if let input = content.inputDisplay, !input.isEmpty {
        Text(input)
          .font(.system(size: TypeScale.body))
          .foregroundStyle(Color.textSecondary)
      }

      // Transcript excerpt as muted quote
      if let excerpt = content.outputDisplay, !excerpt.isEmpty {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text("Context")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textTertiary)
          Text(excerpt)
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textQuaternary)
            .padding(Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
              Rectangle()
                .fill(Color.textQuaternary.opacity(0.2))
                .frame(width: 2)
            }
            .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.sm))
        }
      }

      if let output = content.outputDisplay, !output.isEmpty {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text("Result")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textTertiary)
          Text(output)
            .font(.system(size: TypeScale.code, design: .monospaced))
            .foregroundStyle(Color.textSecondary)
            .padding(Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.sm))
        }
      }
    }
  }
}
