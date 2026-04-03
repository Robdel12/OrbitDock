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
      case let .commandExecution(commandExecution):
        return commandExecutionTint(commandExecution)
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
        toolTypeDots

        Text(groupSummaryText)
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textTertiary)
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

  // MARK: - Tool Type Dots

  private var toolTypeDots: some View {
    HStack(spacing: 3) {
      ForEach(Array(group.children.prefix(8).enumerated()), id: \.offset) { _, child in
        Circle()
          .fill(childTint(child))
          .frame(width: 6, height: 6)
      }
      if group.childCount > 8 {
        Text("…")
          .font(.system(size: 8))
          .foregroundStyle(Color.textQuaternary)
      }
    }
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
      case let .commandExecution(commandExecution):
        return commandExecution.commandActions.first.map(commandExecutionActionTitle(_:)) ?? "Run command"
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
      case let .commandExecution(commandExecution):
        if let command = commandExecutionPrimaryCommand(commandExecution) {
          return command
        }
        if let previewLine = commandExecution.preview?.lines.first?.trimmingCharacters(in: .whitespacesAndNewlines),
           !previewLine.isEmpty
        {
          return previewLine
        }
        return ToolCardStyle.shortenPath(commandExecution.cwd)
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
          clients: clients,
          fetchedContent: contentForChild?(tool.id),
          isLoadingContent: isChildLoading?(tool.id) ?? false,
          onToggle: { onToggle?(tool.id) }
        )
      case let .commandExecution(commandExecution):
        CommandExecutionRowView(
          row: commandExecution,
          isExpanded: isItemExpanded?(commandExecution.id) ?? false,
          fetchedContent: contentForChild?(commandExecution.id),
          isLoadingContent: isChildLoading?(commandExecution.id) ?? false,
          onToggle: { onToggle?(commandExecution.id) }
        )
    }
  }

  private func childTint(_ child: ServerConversationActivityGroupChild) -> Color {
    switch child {
      case let .tool(tool):
        return ToolCardView.resolveColor(tool.toolDisplay.glyphColor)
      case let .commandExecution(commandExecution):
        return commandExecutionTint(commandExecution)
    }
  }

  private func childGlyphSymbol(_ child: ServerConversationActivityGroupChild) -> String {
    switch child {
      case let .tool(tool):
        return tool.toolDisplay.glyphSymbol
      case let .commandExecution(commandExecution):
        return commandExecutionGlyph(commandExecution)
    }
  }

  private func childTypeLabel(_ child: ServerConversationActivityGroupChild) -> String {
    switch child {
      case let .tool(tool):
        return displayTypeLabel(for: tool.toolDisplay.toolType)
      case let .commandExecution(commandExecution):
        return commandExecution.commandActions.first.map(commandExecutionActionTitle(_:)) ?? "Command"
    }
  }

  private func displayTypeLabel(for toolType: String) -> String {
    switch toolType {
      case "dynamicTool": return "Dynamic Tool"
      case "toolSearch": return "Tool Search"
      case "webSearch": return "Web Search"
      case "webFetch": return "Web Fetch"
      case "guardianAssessment": return "Guardian Review"
      case "compactContext": return "Compact Context"
      default: return toolType.capitalized
    }
  }

  private func commandExecutionActionTypesMatch(
    _ row: ServerConversationCommandExecutionRow,
    _ types: [ServerConversationCommandActionType]
  ) -> Bool {
    row.commandActions.allSatisfy { types.contains($0.type) }
  }

  private func commandExecutionTint(_ row: ServerConversationCommandExecutionRow) -> Color {
    if commandExecutionActionTypesMatch(row, [.read]) {
      return .toolRead
    }
    if commandExecutionActionTypesMatch(row, [.search, .listFiles]) {
      return .toolSearch
    }
    return .toolBash
  }

  private func commandExecutionGlyph(_ row: ServerConversationCommandExecutionRow) -> String {
    if commandExecutionActionTypesMatch(row, [.read]) {
      return "doc.text.fill"
    }
    if commandExecutionActionTypesMatch(row, [.search]) {
      return "magnifyingglass"
    }
    if commandExecutionActionTypesMatch(row, [.listFiles]) {
      return "folder.fill"
    }
    return "terminal"
  }

  private func commandExecutionActionTitle(_ action: ServerConversationCommandAction) -> String {
    switch action.type {
      case .read:
        return "Read"
      case .search:
        return "Search"
      case .listFiles:
        return "List files"
      case .unknown:
        return "Run command"
    }
  }

  private func commandExecutionPrimaryCommand(_ row: ServerConversationCommandExecutionRow) -> String? {
    guard !row.commandActions.isEmpty else { return nil }
    guard !commandExecutionActionTypesMatch(row, [.read, .search, .listFiles]) else { return nil }
    let command = row.command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !command.isEmpty else { return nil }
    return command
  }

  private func nonEmpty(_ text: String?) -> String? {
    guard let text else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
