//
//  PlanExpandedView.swift
//  OrbitDock
//
//  Server-driven plan tool expanded view.
//  Shows plan explanation, progress, and step timeline from strongly-typed data.
//

import SwiftUI

struct PlanExpandedView: View {
  let content: ServerRowContent
  let toolRow: ServerConversationToolRow
  let display: ServerToolDisplay?

  private var isExit: Bool {
    toolRow.kind == .exitPlanMode
  }

  private var isUpdate: Bool {
    toolRow.kind == .updatePlan
  }

  private var modeLabel: String {
    switch toolRow.kind {
      case .enterPlanMode: "Entering Plan Mode"
      case .exitPlanMode: "Plan Complete"
      case .updatePlan: "Plan Updated"
      default: "Plan"
    }
  }

  private var modeIcon: String {
    isExit ? "checkmark.circle.fill" : "map"
  }

  private var modeColor: Color {
    isExit ? .feedbackPositive : .toolPlan
  }

  private var steps: [ServerToolTodoItem] {
    display?.todoItems ?? []
  }

  private var completedCount: Int {
    steps.filter { $0.status == "completed" }.count
  }

  private var inProgressCount: Int {
    steps.filter { $0.status == "in_progress" }.count
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      // Mode badge
      HStack(spacing: Spacing.xs) {
        Image(systemName: modeIcon)
          .font(.system(size: IconScale.sm))
          .foregroundStyle(modeColor)
        Text(modeLabel)
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(modeColor)
      }
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xxs)
      .background(modeColor.opacity(OpacityTier.subtle), in: Capsule())

      // Plan explanation
      if let explanation = display?.planExplanation, !explanation.isEmpty {
        Text(explanation)
          .font(.system(size: TypeScale.body))
          .foregroundStyle(Color.textSecondary)
          .padding(Spacing.sm)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(modeColor.opacity(OpacityTier.tint), in: RoundedRectangle(cornerRadius: Radius.sm))
      }

      // Plan steps from server-driven todoItems
      if !steps.isEmpty {
        planStepList()
      } else {
        // Fallback to input/output display if no steps
        fallbackDisplay()
      }
    }
  }

  @ViewBuilder
  private func planStepList() -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      // Progress bar
      ProgressSummaryBar(completed: completedCount, total: steps.count, barColor: modeColor)

      // Timeline steps
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
          planStepRow(step, isLast: index == steps.count - 1)
        }
      }
    }
  }

  private func planStepRow(_ item: ServerToolTodoItem, isLast: Bool) -> some View {
    let isCompleted = item.status == "completed"
    let isInProgress = item.status == "in_progress"

    return HStack(alignment: .top, spacing: Spacing.md) {
      // Timeline column: icon + connecting line
      VStack(spacing: 0) {
        Image(systemName: stepIcon(item.status))
          .font(.system(size: IconScale.md))
          .foregroundStyle(stepColor(item.status))

        if !isLast {
          Rectangle()
            .fill(stepColor(item.status).opacity(0.3))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
        }
      }
      .frame(width: 16)

      // Step content
      VStack(alignment: .leading, spacing: Spacing.xxs) {
        Text(item.content ?? item.status)
          .font(.system(size: TypeScale.body))
          .foregroundStyle(isCompleted ? Color.textTertiary : Color.textSecondary)
          .strikethrough(isCompleted, color: Color.textQuaternary)

        // Show activeForm for in-progress items
        if isInProgress, let activeForm = item.activeForm, !activeForm.isEmpty {
          Text(activeForm)
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textTertiary)
        }
      }
      .padding(.bottom, Spacing.md)
    }
  }

  @ViewBuilder
  private func fallbackDisplay() -> some View {
    // Show input display if available
    if let input = content.inputDisplay, !input.isEmpty {
      Text(input)
        .font(.system(size: TypeScale.body))
        .foregroundStyle(Color.textSecondary)
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(modeColor.opacity(OpacityTier.tint), in: RoundedRectangle(cornerRadius: Radius.sm))
    }

    // Show output display if available
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

  private func stepIcon(_ status: String) -> String {
    switch status {
      case "completed": "checkmark.circle.fill"
      case "in_progress": "circle.dotted"
      default: "circle"
    }
  }

  private func stepColor(_ status: String) -> Color {
    switch status {
      case "completed": .feedbackPositive
      case "in_progress": .accent
      default: .textQuaternary
    }
  }
}
