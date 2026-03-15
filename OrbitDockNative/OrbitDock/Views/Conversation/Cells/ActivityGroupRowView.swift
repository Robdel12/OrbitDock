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

  private var statusColor: Color {
    group.status == .completed ? .feedbackPositive : .accent
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      groupHeader
        .contentShape(Rectangle())
        .onTapGesture { onToggle?(group.id) }

      if isExpanded {
        VStack(spacing: Spacing.xxs) {
          ForEach(group.children, id: \.id) { child in
            ToolCardView(
              toolRow: child,
              isExpanded: isItemExpanded?(child.id) ?? false,
              sessionId: sessionId,
              clients: clients,
              fetchedContent: contentForChild?(child.id),
              isLoadingContent: isChildLoading?(child.id) ?? false,
              onToggle: { onToggle?(child.id) }
            )
          }
        }
        .padding(.top, Spacing.xs)
      }
    }
    .padding(.vertical, Spacing.xxs)
  }

  // MARK: - Collapsed Header

  private var groupHeader: some View {
    HStack(spacing: Spacing.sm) {
      // Chevron
      Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
        .font(.system(size: 8, weight: .bold))
        .foregroundStyle(Color.textQuaternary)
        .frame(width: 12)

      // Tool type indicator dots — colored by tool family
      toolTypeDots

      // Summary text
      Text(groupSummaryText)
        .font(.system(size: TypeScale.caption))
        .foregroundStyle(Color.textTertiary)

      Spacer(minLength: 0)
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
          .fill(ToolCardView.resolveColor(child.toolDisplay?.glyphColor ?? "gray"))
          .frame(width: 6, height: 6)
      }
      if group.childCount > 8 {
        Text("…")
          .font(.system(size: 8))
          .foregroundStyle(Color.textQuaternary)
      }
    }
  }

  // MARK: - Summary

  private var groupSummaryText: String {
    // Build a concise summary like "Read, Edit, Bash"
    let toolNames = group.children.prefix(4).map { child in
      child.toolDisplay?.summary ?? child.title
    }
    let joined = toolNames.joined(separator: ", ")
    if group.childCount > 4 {
      return "\(joined) + \(group.childCount - 4) more"
    }
    return joined
  }
}
