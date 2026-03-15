//
//  TaskExpandedView.swift
//  OrbitDock
//
//  Agent mission card — shows what a sub-agent was dispatched to do
//  and what it accomplished. Designed as a "deployment briefing" card
//  with identity header, mission prompt, and structured output.
//

import SwiftUI

struct TaskExpandedView: View {
  let content: ServerRowContent
  let toolRow: ServerConversationToolRow

  // MARK: - Extracted fields

  private var invocationDict: [String: Any]? {
    toolRow.invocation.value as? [String: Any]
  }

  private var agentType: String? {
    invocationDict?["subagent_type"] as? String
  }

  private var agentDescription: String? {
    invocationDict?["description"] as? String
  }

  private var agentPrompt: String? {
    invocationDict?["prompt"] as? String
  }

  private var agentModel: String? {
    invocationDict?["model"] as? String
  }

  private var isBackground: Bool {
    invocationDict?["run_in_background"] as? Bool ?? false
  }

  private var isIsolated: Bool {
    (invocationDict?["isolation"] as? String) == "worktree"
  }

  private var isRunning: Bool {
    toolRow.status == .running || toolRow.status == .pending
  }

  private var isFailed: Bool {
    toolRow.status == .failed
  }

  private var isCompleted: Bool {
    toolRow.status == .completed
  }

  private var statusColor: Color {
    if isFailed { return .feedbackNegative }
    if isRunning { return .statusWorking }
    return .feedbackPositive
  }

  private var agentIcon: String {
    switch agentType?.lowercased() {
    case "explore": return "binoculars"
    case "plan": return "map"
    case "general-purpose": return "cpu"
    default: return "person.2.fill"
    }
  }

  private var agentColor: Color {
    switch agentType?.lowercased() {
    case "explore": return .toolSearch
    case "plan": return .toolPlan
    default: return .toolTask
    }
  }

  // MARK: - Body

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // ── Identity header ──────────────────────────────────────────────
      agentIdentityHeader

      // ── Mission prompt ───────────────────────────────────────────────
      if let prompt = content.inputDisplay ?? agentPrompt, !prompt.isEmpty {
        missionSection(prompt)
      }

      // ── Result output ────────────────────────────────────────────────
      if let output = content.outputDisplay, !output.isEmpty {
        resultSection(output)
      }
    }
  }

  // MARK: - Identity Header

  private var agentIdentityHeader: some View {
    HStack(spacing: Spacing.sm) {
      // Agent type icon + badge
      HStack(spacing: Spacing.xs) {
        Image(systemName: agentIcon)
          .font(.system(size: IconScale.sm, weight: .semibold))
          .foregroundStyle(agentColor)

        if let type = agentType {
          Text(type.capitalized)
            .font(.system(size: TypeScale.caption, weight: .bold))
            .foregroundStyle(agentColor)
        }
      }
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xs)
      .background(agentColor.opacity(OpacityTier.subtle), in: Capsule())

      // Status indicator
      HStack(spacing: Spacing.xs) {
        Circle()
          .fill(statusColor)
          .frame(width: 5, height: 5)
        Text(statusLabel)
          .font(.system(size: TypeScale.mini, weight: .medium))
          .foregroundStyle(statusColor)
      }

      Spacer()

      // Metadata pills
      HStack(spacing: Spacing.sm_) {
        if isIsolated {
          metadataPill(icon: "arrow.triangle.branch", label: "Worktree")
        }

        if isBackground {
          metadataPill(icon: "arrow.down.circle", label: "Background")
        }

        if let model = agentModel {
          metadataPill(icon: nil, label: shortenModel(model))
        }

        if let duration = toolRow.durationMs {
          Text(formatDuration(duration))
            .font(.system(size: TypeScale.mini, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)
        }
      }
    }
    .padding(.bottom, Spacing.md)
  }

  private var statusLabel: String {
    if isRunning { return "Working" }
    if isFailed { return "Failed" }
    if isCompleted { return "Done" }
    return toolRow.status.rawValue.capitalized
  }

  // MARK: - Mission Section

  private func missionSection(_ prompt: String) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      // Section label with thin connecting line
      HStack(spacing: Spacing.xs) {
        Rectangle()
          .fill(agentColor.opacity(0.3))
          .frame(width: 12, height: 1)
        Text("Mission")
          .font(.system(size: TypeScale.mini, weight: .bold))
          .foregroundStyle(agentColor.opacity(0.7))
          .textCase(.uppercase)
          .tracking(0.8)
      }

      // Prompt content — the actual task description
      Text(prompt)
        .font(.system(size: TypeScale.body))
        .foregroundStyle(Color.textSecondary)
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
          RoundedRectangle(cornerRadius: Radius.sm)
            .fill(agentColor.opacity(OpacityTier.tint))
        }
        .overlay(alignment: .leading) {
          UnevenRoundedRectangle(
            topLeadingRadius: Radius.sm, bottomLeadingRadius: Radius.sm,
            bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous
          )
          .fill(agentColor.opacity(0.35))
          .frame(width: 2)
        }
    }
    .padding(.bottom, Spacing.md)
  }

  // MARK: - Result Section

  private func resultSection(_ output: String) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      HStack(spacing: Spacing.xs) {
        Rectangle()
          .fill(Color.textQuaternary.opacity(0.3))
          .frame(width: 12, height: 1)
        Text("Result")
          .font(.system(size: TypeScale.mini, weight: .bold))
          .foregroundStyle(Color.textQuaternary)
          .textCase(.uppercase)
          .tracking(0.8)

        if isFailed {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: IconScale.xs))
            .foregroundStyle(Color.feedbackNegative)
        }
      }

      Text(output)
        .font(.system(size: TypeScale.code, design: .monospaced))
        .foregroundStyle(isFailed ? Color.feedbackNegative.opacity(0.8) : Color.textSecondary)
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          isFailed
            ? Color.feedbackNegative.opacity(OpacityTier.tint)
            : Color.backgroundCode,
          in: RoundedRectangle(cornerRadius: Radius.sm)
        )
    }
  }

  // MARK: - Helpers

  private func metadataPill(icon: String?, label: String) -> some View {
    HStack(spacing: Spacing.xxs) {
      if let icon {
        Image(systemName: icon)
          .font(.system(size: 7))
      }
      Text(label)
        .font(.system(size: TypeScale.mini, weight: .medium))
    }
    .foregroundStyle(Color.textQuaternary)
    .padding(.horizontal, Spacing.sm_)
    .padding(.vertical, 1)
    .background(Color.textQuaternary.opacity(OpacityTier.tint), in: Capsule())
  }

  private func shortenModel(_ model: String) -> String {
    // "sonnet" → "Sonnet", "opus" → "Opus", "haiku" → "Haiku"
    if model.contains("opus") { return "Opus" }
    if model.contains("sonnet") { return "Sonnet" }
    if model.contains("haiku") { return "Haiku" }
    return model
  }

  private func formatDuration(_ ms: UInt64) -> String {
    if ms < 1000 { return "\(ms)ms" }
    let seconds = Double(ms) / 1000
    if seconds < 60 { return String(format: "%.1fs", seconds) }
    let minutes = Int(seconds) / 60
    let secs = Int(seconds) % 60
    return "\(minutes)m \(secs)s"
  }
}
