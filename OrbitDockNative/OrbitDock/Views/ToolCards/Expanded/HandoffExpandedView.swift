//
//  HandoffExpandedView.swift
//  OrbitDock
//
//  Handoff expanded view with target badge and markdown body.
//

import SwiftUI

struct HandoffExpandedView: View {
  let content: ServerRowContent
  let toolRow: ServerConversationToolRow

  private var targetName: String? {
    guard let dict = toolRow.invocation.value as? [String: Any] else { return nil }
    return dict["target"] as? String ?? dict["to"] as? String
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      HStack(spacing: Spacing.sm) {
        Image(systemName: "arrow.triangle.branch")
          .font(.system(size: IconScale.sm))
          .foregroundStyle(Color.statusReply)

        Text("Handoff")
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.textTertiary)

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
