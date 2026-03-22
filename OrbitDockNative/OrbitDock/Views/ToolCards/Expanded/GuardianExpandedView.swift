//
//  GuardianExpandedView.swift
//  OrbitDock
//
//  Guardian assessment expanded view — shows verdict, risk level, and rationale
//  as a structured review card rather than raw JSON.
//

import SwiftUI

struct GuardianExpandedView: View {
  let content: ServerRowContent
  let toolRow: ServerConversationToolRow

  private var assessment: ParsedAssessment {
    parseAssessment(content.outputDisplay)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      // Reviewed action
      if let input = content.inputDisplay, !input.isEmpty {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text("Reviewed Action")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textTertiary)
          Text(input)
            .font(.system(size: TypeScale.code, design: .monospaced))
            .foregroundStyle(Color.textSecondary)
            .padding(Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.sm))
        }
      }

      // Assessment result card
      let result = assessment
      VStack(alignment: .leading, spacing: Spacing.sm) {
        // Verdict badge
        if let verdict = result.verdict {
          HStack(spacing: Spacing.xs) {
            Image(systemName: "shield.lefthalf.filled")
              .font(.system(size: IconScale.sm))
              .foregroundStyle(verdictColor(verdict))
            Text(verdict.capitalized)
              .font(.system(size: TypeScale.body, weight: .bold))
              .foregroundStyle(verdictColor(verdict))
            Spacer()
            verdictPill(verdict)
          }
        }

        // Risk level
        if let risk = result.risk {
          HStack(spacing: Spacing.sm) {
            Text("Risk")
              .font(.system(size: TypeScale.caption, weight: .semibold))
              .foregroundStyle(Color.textTertiary)
              .frame(width: 60, alignment: .trailing)
            Text(risk)
              .font(.system(size: TypeScale.caption))
              .foregroundStyle(Color.textSecondary)
          }
        }

        // Rationale
        if let rationale = result.rationale {
          VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Rationale")
              .font(.system(size: TypeScale.caption, weight: .semibold))
              .foregroundStyle(Color.textTertiary)
            Text(rationale)
              .font(.system(size: TypeScale.body))
              .foregroundStyle(Color.textSecondary)
          }
        }
      }
      .padding(Spacing.sm)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
          .fill(Color.backgroundCode)
          .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
              .fill(Color.feedbackCaution.opacity(0.9))
              .frame(width: 3)
              .padding(.vertical, Spacing.sm_)
              .padding(.leading, 1)
          }
      )

      // Fallback: raw output if nothing was parsed
      if result.verdict == nil, result.risk == nil, result.rationale == nil,
         let output = content.outputDisplay, !output.isEmpty
      {
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

  // MARK: - Verdict Helpers

  private func verdictColor(_ verdict: String) -> Color {
    switch verdict.lowercased() {
      case "approved": .feedbackPositive
      case "denied": .feedbackNegative
      case "reviewing": .feedbackCaution
      case "aborted": .feedbackNegative
      default: .textTertiary
    }
  }

  @ViewBuilder
  private func verdictPill(_ verdict: String) -> some View {
    let color = verdictColor(verdict)
    HStack(spacing: Spacing.xxs) {
      Circle()
        .fill(color)
        .frame(width: 5, height: 5)
      Text(verdict.uppercased())
        .font(.system(size: TypeScale.mini, weight: .bold, design: .rounded))
        .foregroundStyle(color)
    }
    .padding(.horizontal, Spacing.sm_)
    .padding(.vertical, Spacing.xxs)
    .background(
      Capsule()
        .fill(color.opacity(OpacityTier.subtle))
        .overlay(Capsule().strokeBorder(color.opacity(0.2), lineWidth: 1))
    )
  }

  // MARK: - Parsing

  private struct ParsedAssessment {
    var verdict: String?
    var risk: String?
    var rationale: String?
  }

  private func parseAssessment(_ output: String?) -> ParsedAssessment {
    guard let output, !output.isEmpty else { return ParsedAssessment() }

    var result = ParsedAssessment()
    for line in output.components(separatedBy: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("Verdict:") {
        result.verdict = String(trimmed.dropFirst("Verdict:".count)).trimmingCharacters(in: .whitespaces)
      } else if trimmed.hasPrefix("Risk:") {
        result.risk = String(trimmed.dropFirst("Risk:".count)).trimmingCharacters(in: .whitespaces)
      } else if trimmed.hasPrefix("Rationale:") {
        result.rationale = String(trimmed.dropFirst("Rationale:".count)).trimmingCharacters(in: .whitespaces)
      }
    }
    return result
  }
}
