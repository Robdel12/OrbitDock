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

  private var latestChild: ServerConversationToolRow? {
    group.children.last
  }

  private var latestChildTint: Color {
    guard let latestChild else { return .accent }
    return ToolCardView.resolveColor(latestChild.toolDisplay.glyphColor)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      groupHeader
        .contentShape(Rectangle())
        .onTapGesture { onToggle?(group.id) }

      if isExpanded {
        VStack(spacing: Spacing.xs) {
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
          .fill(ToolCardView.resolveColor(child.toolDisplay.glyphColor))
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

            Image(systemName: latestChild.toolDisplay.glyphSymbol)
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
    "\(group.childCount) \(group.title)"
  }

  private var groupSummaryText: String {
    var counts: [(type: String, count: Int)] = []
    var seen: [String: Int] = [:]

    for child in group.children {
      let type = child.toolDisplay.toolType.capitalized
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

  private func latestChildLabel(_ child: ServerConversationToolRow) -> String {
    let text = child.toolDisplay.summary.isEmpty ? child.title : child.toolDisplay.summary
    return text.isEmpty ? child.toolDisplay.toolType.capitalized : text
  }

  private func latestChildSupportingText(_ child: ServerConversationToolRow) -> String? {
    if let subtitle = nonEmpty(child.toolDisplay.subtitle) {
      return ToolCardStyle.shortenPath(subtitle)
    }
    if let meta = nonEmpty(child.toolDisplay.rightMeta) {
      return meta
    }
    return child.toolDisplay.toolType.capitalized
  }

  private func nonEmpty(_ text: String?) -> String? {
    guard let text else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
