//
//  PlanExpandedView.swift
//  OrbitDock
//
//  Plan mode expanded view with mode badges.
//

import SwiftUI

struct PlanExpandedView: View {
  let content: ServerRowContent
  let toolRow: ServerConversationToolRow

  private var modeLabel: String {
    switch toolRow.kind {
    case .enterPlanMode: "Entering Plan Mode"
    case .exitPlanMode: "Exiting Plan Mode"
    case .updatePlan: "Plan Updated"
    default: "Plan"
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      // Mode badge
      HStack(spacing: Spacing.xs) {
        Image(systemName: "map")
          .font(.system(size: IconScale.sm))
          .foregroundStyle(Color.toolPlan)
        Text(modeLabel)
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.toolPlan)
          .padding(.horizontal, Spacing.sm)
          .padding(.vertical, Spacing.xxs)
          .background(Color.toolPlan.opacity(OpacityTier.subtle), in: Capsule())
      }

      if let input = content.inputDisplay, !input.isEmpty {
        Text(input)
          .font(.system(size: TypeScale.body))
          .foregroundStyle(Color.textSecondary)
          .padding(Spacing.sm)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.toolPlan.opacity(OpacityTier.tint), in: RoundedRectangle(cornerRadius: Radius.sm))
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
