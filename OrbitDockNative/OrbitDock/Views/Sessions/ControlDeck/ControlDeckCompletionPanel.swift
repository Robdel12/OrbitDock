import SwiftUI

struct ControlDeckCompletionPanel: View {
  let mode: ControlDeckCompletionMode
  let suggestions: [ControlDeckCompletionSuggestion]
  let selectedIndex: Int
  let onSelect: (ControlDeckCompletionSuggestion) -> Void

  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  private var isCompactIOS: Bool {
    #if os(iOS)
      horizontalSizeClass == .compact
    #else
      false
    #endif
  }

  private var rowHeight: CGFloat {
    isCompactIOS ? 50 : 44
  }

  private var visibleRowCount: Int {
    let cap = isCompactIOS ? 6 : 10
    return min(max(suggestions.count, 1), cap)
  }

  private var listMaxHeight: CGFloat {
    CGFloat(visibleRowCount) * rowHeight + (Spacing.xs * 2)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      divider
      list
    }
    .background(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .fill(Color.panelBackground)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .strokeBorder(Color.panelBorder, lineWidth: 1)
    )
    .fixedSize(horizontal: false, vertical: true)
    .compositingGroup()
    .themeShadow(Shadow.lg)
  }

  private var header: some View {
    HStack(spacing: Spacing.xs) {
      Image(systemName: headerIcon)
        .font(.system(size: TypeScale.micro, weight: .bold))
        .foregroundStyle(headerTint)

      Text(headerTitle)
        .font(.system(size: TypeScale.mini, weight: .semibold))
        .foregroundStyle(Color.textPrimary)

      if !suggestions.isEmpty {
        Text("\(suggestions.count)")
          .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
          .foregroundStyle(Color.textTertiary)
      }

      Spacer(minLength: 0)

      if !isCompactIOS {
        Text("↑↓ move · tab insert · esc dismiss")
          .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.textQuaternary)
      }
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.sm_)
  }

  private var list: some View {
    Group {
      if suggestions.isEmpty {
        emptyState
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: Spacing.xxs) {
            ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
              suggestionRow(suggestion, index: index)
            }
          }
          .padding(.horizontal, Spacing.xxs)
          .padding(.vertical, Spacing.xxs)
        }
        .scrollIndicators(.hidden)
        .frame(minHeight: listMaxHeight, maxHeight: listMaxHeight, alignment: .top)
        .clipped()
      }
    }
    .padding(.vertical, Spacing.xxs)
  }

  private func suggestionRow(_ suggestion: ControlDeckCompletionSuggestion, index: Int) -> some View {
    let isSelected = index == selectedIndex
    let hasSubtitle = !(suggestion.subtitle?.isEmpty ?? true)

    return Button { onSelect(suggestion) } label: {
      HStack(spacing: Spacing.sm) {
        Image(systemName: icon(for: suggestion.kind))
          .font(.system(size: TypeScale.mini, weight: .bold))
          .foregroundStyle(tint(for: suggestion.kind))
          .frame(width: 16)

        VStack(alignment: .leading, spacing: Spacing.gap) {
          Text(suggestion.title)
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textPrimary)
            .lineLimit(1)

          if let subtitle = suggestion.subtitle, !subtitle.isEmpty {
            Text(subtitle)
              .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
              .foregroundStyle(Color.textTertiary)
              .lineLimit(1)
          }
        }

        Spacer(minLength: 0)

        if isSelected, !isCompactIOS {
          Text("tab")
            .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, Spacing.gap)
            .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous))
        }
      }
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, hasSubtitle ? Spacing.sm_ : Spacing.xs)
      .frame(minHeight: rowHeight)
      .background(
        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
          .fill(isSelected ? Color.backgroundTertiary.opacity(0.9) : Color.clear)
      )
      .overlay(alignment: .leading) {
        RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
          .fill(Color.accent)
          .frame(width: 2)
          .padding(.vertical, Spacing.sm_)
          .opacity(isSelected ? 1 : 0)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private var emptyState: some View {
    HStack(spacing: Spacing.xs) {
      Image(systemName: headerIcon)
        .font(.system(size: TypeScale.mini, weight: .semibold))
        .foregroundStyle(Color.textQuaternary)

      Text(emptyStateText)
        .font(.system(size: TypeScale.caption, weight: .medium))
        .foregroundStyle(Color.textSecondary)
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.sm)
    .frame(minHeight: rowHeight)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var divider: some View {
    Rectangle()
      .fill(Color.panelBorder.opacity(OpacityTier.medium))
      .frame(height: 1)
  }

  private var headerTitle: String {
    switch mode {
      case .mention: "Files"
      case .skill: "Skills"
      case .command: "Commands"
      case .inactive: "Suggestions"
    }
  }

  private var headerIcon: String {
    switch mode {
      case .mention: "at"
      case .skill: "bolt.fill"
      case .command: "slash.circle"
      case .inactive: "text.cursor"
    }
  }

  private var headerTint: Color {
    switch mode {
      case .mention: .providerCodex
      case .skill: .accent
      case .command: .statusQuestion
      case .inactive: .textSecondary
    }
  }

  private var emptyStateText: String {
    switch mode {
      case let .mention(query), let .skill(query), let .command(query):
        return query.isEmpty ? "Type to search" : "No matches found"
      case .inactive:
        return "Type to search"
    }
  }

  private func icon(for kind: ControlDeckCompletionSuggestion.Kind) -> String {
    switch kind {
      case .file: "at"
      case .skill: "bolt.fill"
      case .command: "slash.circle"
    }
  }

  private func tint(for kind: ControlDeckCompletionSuggestion.Kind) -> Color {
    switch kind {
      case .file: .providerCodex
      case .skill: .accent
      case .command: .statusQuestion
    }
  }
}
