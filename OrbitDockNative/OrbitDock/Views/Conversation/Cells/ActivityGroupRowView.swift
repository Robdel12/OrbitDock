//
//  ActivityGroupRowView.swift
//  OrbitDock
//
//  Collapsible tool group with visual tool-type indicator strip.
//  Collapsed: colored dots showing tool mix + summary text.
//  Expanded: child tool cards.
//

import SwiftUI

struct ActivityGroupRowView: View {
  let group: ServerConversationActivityGroupRow
  let isExpanded: Bool
  var sessionId: String = ""
  var endpointId: UUID?
  var clients: ServerClients?
  var onToggle: ((String) -> Void)?
  var isItemExpanded: ((String) -> Bool)?
  var contentForChild: ((String) -> ServerRowContent?)?
  var isChildLoading: ((String) -> Bool)?

  @Environment(\.horizontalSizeClass) private var sizeClass

  private var isCompactLayout: Bool {
    sizeClass == .compact
  }

  private var latestChild: ServerConversationActivityGroupChild? {
    group.children.last
  }

  private var latestChildTint: Color {
    guard let latestChild else { return .accent }
    switch latestChild {
      case let .tool(tool):
        return ToolCardView.resolveColor(tool.toolDisplay.glyphColor)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      groupHeader
        .contentShape(Rectangle())
        .onTapGesture { onToggle?(group.id) }

      if isExpanded {
        VStack(spacing: Spacing.xs) {
          ForEach(group.children, id: \.id) { child in
            childView(child)
          }
        }
        .padding(.top, Spacing.xs)
      }
    }
    .padding(.vertical, sizeClass == .compact ? Spacing.xs : Spacing.xxs)
  }

  // MARK: - Collapsed Header

  private var groupHeader: some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
        .font(.system(size: 8, weight: .bold))
        .foregroundStyle(Color.textQuaternary)
        .frame(width: 12)

      if isExpanded {
        activitySummaries
      } else {
        latestChildPreview
      }

      Spacer(minLength: 0)

      if !isExpanded {
        groupCountCapsule
      }
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.sm_)
    .background(
      RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
        .fill(Color.backgroundTertiary.opacity(0.5))
    )
  }

  // MARK: - Smart Activity Summaries

  /// Aggregated summaries by tool family
  private var activitySummaries: some View {
    let summaries = computeActivitySummaries()

    return HStack(spacing: Spacing.md) {
      ForEach(summaries, id: \.label) { summary in
        HStack(spacing: Spacing.xs) {
          Image(systemName: summary.icon)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(summary.color.opacity(0.7))

          Text(summary.label)
            .font(.system(size: TypeScale.caption, weight: .medium))
            .foregroundStyle(Color.textTertiary)

          if let detail = summary.detail {
            Text(detail)
              .font(.system(size: TypeScale.caption, weight: .semibold, design: .monospaced))
              .foregroundStyle(summary.color)
          }
        }
      }
    }
  }

  private struct ActivitySummary {
    let icon: String
    let label: String
    let detail: String?
    let color: Color
  }

  private func computeActivitySummaries() -> [ActivitySummary] {
    var summaries: [ActivitySummary] = []

    // Aggregate file changes
    var editCount = 0
    var totalAdditions: UInt32 = 0
    var totalDeletions: UInt32 = 0

    // Aggregate search results
    var searchCount = 0
    var totalMatches = 0

    // Track bash commands
    var bashCommands: [(command: String, passed: Bool)] = []

    for child in group.children {
      let tool = child.tool
      let toolType = tool.toolDisplay.toolType
      switch toolType {
        case "edit", "write":
          editCount += 1
          if let preview = tool.toolDisplay.diffPreview {
            totalAdditions += preview.additions
            totalDeletions += preview.deletions
          }

        case "grep", "glob", "toolSearch":
          searchCount += 1
          if let meta = tool.toolDisplay.rightMeta {
            // Parse "12 results" to get the number
            let digits = meta.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
            if let count = Int(digits) {
              totalMatches += count
            }
          }

        case "bash":
          let command = extractBashCommand(from: tool)
          let passed = tool.status == .completed
          bashCommands.append((command, passed))

        default:
          break
      }
    }

    // Build summaries (most impactful first)

    // File edits with diff stats
    if editCount > 0 {
      let fileWord = editCount == 1 ? "file" : "files"
      var detail: String?
      if totalAdditions > 0 || totalDeletions > 0 {
        var parts: [String] = []
        if totalAdditions > 0 { parts.append("+\(totalAdditions)") }
        if totalDeletions > 0 { parts.append("-\(totalDeletions)") }
        detail = parts.joined(separator: "/")
      }
      summaries.append(ActivitySummary(
        icon: "pencil.line",
        label: "\(editCount) \(fileWord)",
        detail: detail,
        color: Color.toolWrite
      ))
    }

    // Bash with outcome
    if !bashCommands.isEmpty {
      if bashCommands.count == 1 {
        let cmd = bashCommands[0]
        let shortCmd = cmd.command.count > 20 ? String(cmd.command.prefix(18)) + "…" : cmd.command
        summaries.append(ActivitySummary(
          icon: "terminal",
          label: shortCmd,
          detail: cmd.passed ? "✓" : "✗",
          color: cmd.passed ? Color.feedbackPositive : Color.feedbackNegative
        ))
      } else {
        let passed = bashCommands.filter(\.passed).count
        let failed = bashCommands.count - passed
        var detail = "\(passed) passed"
        if failed > 0 { detail += ", \(failed) failed" }
        summaries.append(ActivitySummary(
          icon: "terminal",
          label: "\(bashCommands.count) commands",
          detail: nil,
          color: failed > 0 ? Color.feedbackNegative : Color.feedbackPositive
        ))
      }
    }

    // Search results
    if searchCount > 0 {
      summaries.append(ActivitySummary(
        icon: "magnifyingglass",
        label: totalMatches > 0 ? "\(totalMatches) matches" : "\(searchCount) searches",
        detail: nil,
        color: Color.toolSearch
      ))
    }

    // Limit to 3 summaries max
    return Array(summaries.prefix(3))
  }

  private func extractBashCommand(from tool: ServerConversationToolRow) -> String {
    let input = tool.shellExecution?.command ?? tool.toolDisplay.inputDisplay ?? tool.toolDisplay.summary
    let cleaned = input.hasPrefix("$ ") ? String(input.dropFirst(2)) : input
    return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var latestChildPreview: some View {
    Group {
      if let latestChild {
        HStack(spacing: Spacing.sm) {
          ZStack {
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
              .fill(latestChildTint.opacity(0.14))
              .overlay(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                  .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
              )

            Image(systemName: childGlyphSymbol(latestChild))
              .font(.system(size: IconScale.sm, weight: .semibold))
              .foregroundStyle(latestChildTint)
          }
          .frame(width: isCompactLayout ? 22 : 20, height: isCompactLayout ? 22 : 20)

          VStack(alignment: .leading, spacing: 1) {
            Text(latestChildLabel(latestChild))
              .font(.system(size: TypeScale.caption, weight: .semibold, design: .rounded))
              .foregroundStyle(Color.textSecondary)
              .lineLimit(1)

            if let supporting = latestChildSupportingText(latestChild) {
              Text(supporting)
                .font(.system(size: TypeScale.mini, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.textTertiary)
                .lineLimit(1)
            }
          }
        }
        .id(latestChild.id)
        .transition(
          .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .move(edge: .top).combined(with: .opacity)
          )
        )
      } else {
        Text(groupSummaryText)
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textTertiary)
      }
    }
    .animation(Motion.standard, value: latestChild?.id)
  }

  private var groupCountCapsule: some View {
    Text(groupCountLabel)
      .font(.system(size: TypeScale.mini, weight: .semibold, design: .rounded))
      .foregroundStyle(Color.textTertiary)
      .padding(.horizontal, Spacing.sm_)
      .padding(.vertical, Spacing.xxs)
      .background(
        Capsule()
          .fill(Color.backgroundCode.opacity(0.9))
          .overlay(
            Capsule()
              .strokeBorder(Color.white.opacity(0.04), lineWidth: 1)
          )
      )
  }

  private var groupCountLabel: String {
    let normalizedTitle = group.title.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalizedTitle.contains(String(group.childCount)) {
      return normalizedTitle
    }
    return "\(group.childCount) \(group.childCount == 1 ? "action" : "actions")"
  }

  private var groupSummaryText: String {
    var counts: [(type: String, count: Int)] = []
    var seen: [String: Int] = [:]

    for child in group.children {
      let type = childTypeLabel(child)
      if let idx = seen[type] {
        counts[idx].count += 1
      } else {
        seen[type] = counts.count
        counts.append((type: type, count: 1))
      }
    }

    return counts.map { entry in
      entry.count > 1 ? "\(entry.count) \(entry.type)" : entry.type
    }.joined(separator: ", ")
  }

  private func latestChildLabel(_ child: ServerConversationActivityGroupChild) -> String {
    switch child {
      case let .tool(tool):
        let text = tool.toolDisplay.summary.isEmpty ? tool.title : tool.toolDisplay.summary
        return text.isEmpty ? displayTypeLabel(for: tool.toolDisplay.toolType) : text
    }
  }

  private func latestChildSupportingText(_ child: ServerConversationActivityGroupChild) -> String? {
    switch child {
      case let .tool(tool):
        if let subtitle = nonEmpty(tool.toolDisplay.subtitle) {
          return ToolCardStyle.shortenPath(subtitle)
        }
        if let meta = nonEmpty(tool.toolDisplay.rightMeta) {
          return meta
        }
        return displayTypeLabel(for: tool.toolDisplay.toolType)
    }
  }

  @ViewBuilder
  private func childView(_ child: ServerConversationActivityGroupChild) -> some View {
    switch child {
      case let .tool(tool):
        ToolCardView(
          toolRow: tool,
          isExpanded: isItemExpanded?(tool.id) ?? false,
          sessionId: sessionId,
          endpointId: endpointId,
          clients: clients,
          fetchedContent: contentForChild?(tool.id),
          isLoadingContent: isChildLoading?(tool.id) ?? false,
          onToggle: { onToggle?(tool.id) }
        )
    }
  }

  private func childTint(_ child: ServerConversationActivityGroupChild) -> Color {
    switch child {
      case let .tool(tool):
        return ToolCardView.resolveColor(tool.toolDisplay.glyphColor)
    }
  }

  private func childGlyphSymbol(_ child: ServerConversationActivityGroupChild) -> String {
    switch child {
      case let .tool(tool):
        return tool.toolDisplay.glyphSymbol
    }
  }

  private func childTypeLabel(_ child: ServerConversationActivityGroupChild) -> String {
    switch child {
      case let .tool(tool):
        return displayTypeLabel(for: tool.toolDisplay.toolType)
    }
  }

  private func displayTypeLabel(for toolType: String) -> String {
    switch toolType {
      case "dynamicTool": return "Dynamic Tool"
      case "toolSearch": return "Tool Search"
      case "webSearch": return "Web Search"
      case "webFetch": return "Web Fetch"
      case "guardianAssessment": return "Auto-review"
      case "compactContext": return "Compact Context"
      default: return toolType.capitalized
    }
  }

  private func nonEmpty(_ text: String?) -> String? {
    guard let text else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

private extension ServerConversationActivityGroupChild {
  var tool: ServerConversationToolRow {
    switch self {
      case let .tool(tool):
        tool
    }
  }
}
