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

  @State private var showFullPrompt = false

  // MARK: - Extracted fields

  /// Agent type extracted from server-computed subtitle (format: "type — description").
  private var agentType: String? {
    guard let subtitle = toolRow.toolDisplay.subtitle ?? toolRow.subtitle else { return nil }
    if let dashRange = subtitle.range(of: " — ") {
      return String(subtitle[subtitle.startIndex..<dashRange.lowerBound])
    }
    // Subtitle might be just the type name if no description
    return subtitle.isEmpty ? nil : subtitle
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
      if let prompt = content.inputDisplay ?? toolRow.toolDisplay.inputDisplay, !prompt.isEmpty {
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

      if isRunning, toolRow.startedAt != nil {
        Text("Working...")
          .font(.system(size: TypeScale.mini, weight: .medium))
          .foregroundStyle(statusColor.opacity(0.7))
      }

      Spacer()

      // Metadata pills
      HStack(spacing: Spacing.sm_) {
        if let meta = toolRow.toolDisplay.rightMeta {
          metadataPill(icon: nil, label: meta)
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
    let promptLines = prompt.components(separatedBy: "\n")
    let shouldTruncate = promptLines.count > 5 && !showFullPrompt
    let displayText = shouldTruncate
      ? promptLines.prefix(3).joined(separator: "\n") + "..."
      : prompt

    return VStack(alignment: .leading, spacing: Spacing.xs) {
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
      Text(displayText)
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

      if promptLines.count > 5 {
        Button(action: { withAnimation(Motion.snappy) { showFullPrompt.toggle() } }) {
          Text(showFullPrompt ? "Show less" : "Show full prompt")
            .font(.system(size: TypeScale.mini, weight: .medium))
            .foregroundStyle(agentColor)
        }
        .buttonStyle(.plain)
        .padding(.top, Spacing.xs)
      }
    }
    .padding(.bottom, Spacing.md)
  }

  // MARK: - Result Section

  private func resultSection(_ output: String) -> some View {
    let isJSON = looksLikeJSON(output)
    let isProselike = !isJSON && !output.contains("\n    ") && output.count > 100

    return VStack(alignment: .leading, spacing: Spacing.xs) {
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
        .font(isProselike
          ? .system(size: TypeScale.body)
          : .system(size: TypeScale.code, design: .monospaced))
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

  private func looksLikeJSON(_ text: String) -> Bool {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return (t.hasPrefix("{") && t.hasSuffix("}")) || (t.hasPrefix("[") && t.hasSuffix("]"))
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

  private func formatDuration(_ ms: UInt64) -> String {
    if ms < 1000 { return "\(ms)ms" }
    let seconds = Double(ms) / 1000
    if seconds < 60 { return String(format: "%.1fs", seconds) }
    let minutes = Int(seconds) / 60
    let secs = Int(seconds) % 60
    return "\(minutes)m \(secs)s"
  }
}
