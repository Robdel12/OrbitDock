//
//  PlanExpandedView.swift
//  OrbitDock
//
//  Plan mode expanded view with mode badges.
//  Differentiates enter, exit, and update modes visually.
//

import SwiftUI

struct PlanExpandedView: View {
  let content: ServerRowContent
  let toolRow: ServerConversationToolRow

  private var isExit: Bool { toolRow.kind == .exitPlanMode }
  private var isUpdate: Bool { toolRow.kind == .updatePlan }

  private var modeLabel: String {
    switch toolRow.kind {
    case .enterPlanMode: "Entering Plan Mode"
    case .exitPlanMode: "Plan Complete"
    case .updatePlan: "Plan Updated"
    default: "Plan"
    }
  }

  private var modeIcon: String {
    isExit ? "checkmark.circle" : "map"
  }

  private var modeColor: Color {
    isExit ? .feedbackPositive : .toolPlan
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
          .padding(.horizontal, Spacing.sm)
          .padding(.vertical, Spacing.xxs)
          .background(modeColor.opacity(OpacityTier.subtle), in: Capsule())
      }

      // Phase banner for enter/exit modes
      if !isExit && !isUpdate {
        HStack(spacing: Spacing.xs) {
          Rectangle()
            .fill(modeColor)
            .frame(width: 3, height: 16)
          Text("PLANNING PHASE")
            .font(.system(size: TypeScale.mini, weight: .bold))
            .foregroundStyle(modeColor)
            .tracking(0.8)
        }
      } else if isExit {
        HStack(spacing: Spacing.xs) {
          Rectangle()
            .fill(Color.feedbackPositive)
            .frame(width: 3, height: 16)
          Text("PLAN COMPLETE")
            .font(.system(size: TypeScale.mini, weight: .bold))
            .foregroundStyle(Color.feedbackPositive)
            .tracking(0.8)
        }
      }

      if let input = content.inputDisplay, !input.isEmpty {
        Text(input)
          .font(.system(size: TypeScale.body))
          .foregroundStyle(Color.textSecondary)
          .padding(Spacing.sm)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(modeColor.opacity(OpacityTier.tint), in: RoundedRectangle(cornerRadius: Radius.sm))
      }

      if isUpdate, let output = content.outputDisplay, !output.isEmpty {
        planStepList(output)
      } else if let output = content.outputDisplay, !output.isEmpty {
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

  /// Attempt to parse output as JSON array of plan steps [{title, status}]
  /// Falls back to plain text display.
  @ViewBuilder
  private func planStepList(_ output: String) -> some View {
    let steps = parsePlanSteps(output)
    if steps.isEmpty {
      VStack(alignment: .leading, spacing: Spacing.xs) {
        Text("Plan")
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.textTertiary)
        Text(output)
          .font(.system(size: TypeScale.code, design: .monospaced))
          .foregroundStyle(Color.textSecondary)
          .padding(Spacing.sm)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.sm))
      }
    } else {
      let completed = steps.filter { $0.status == "completed" }.count

      VStack(alignment: .leading, spacing: Spacing.sm) {
        // Progress bar at top
        ProgressSummaryBar(completed: completed, total: steps.count)

        // Timeline steps
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
            HStack(alignment: .top, spacing: Spacing.md) {
              // Timeline column: icon + connecting line
              VStack(spacing: 0) {
                Image(systemName: stepIcon(step.status))
                  .font(.system(size: IconScale.md))
                  .foregroundStyle(stepColor(step.status))

                if index < steps.count - 1 {
                  Rectangle()
                    .fill(stepColor(step.status).opacity(0.3))
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                }
              }
              .frame(width: 16)

              // Step content
              Text(step.title)
                .font(.system(size: TypeScale.body))
                .foregroundStyle(
                  step.status == "completed" ? Color.textTertiary : Color.textSecondary
                )
                .padding(.bottom, Spacing.md)
            }
          }
        }
      }
    }
  }

  private struct PlanStep {
    let title: String
    let status: String
  }

  private func parsePlanSteps(_ json: String) -> [PlanStep] {
    guard let data = json.data(using: .utf8),
          let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return [] }
    return array.compactMap { dict in
      guard let title = dict["title"] as? String else { return nil }
      let status = dict["status"] as? String ?? "pending"
      return PlanStep(title: title, status: status)
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
