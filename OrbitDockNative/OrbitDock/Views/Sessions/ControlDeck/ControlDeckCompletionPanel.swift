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

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: Spacing.sm) {
        HStack(spacing: Spacing.xs) {
          Image(systemName: headerIcon)
            .font(.system(size: TypeScale.micro, weight: .bold))
            .foregroundStyle(headerTint)

          Text(headerTitle)
            .font(.system(size: TypeScale.mini, weight: .semibold))
            .foregroundStyle(Color.textPrimary)

          Text("\(suggestions.prefix(8).count)")
            .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
            .foregroundStyle(Color.textSecondary)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, Spacing.gap)
            .background(Color.backgroundPrimary, in: Capsule())
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(headerTint.opacity(OpacityTier.light), in: Capsule())

        Spacer(minLength: 0)

        if !isCompactIOS {
          HStack(spacing: Spacing.xs) {
            keyHint("\u{2191}\u{2193}")
            keyHint("tab")
            keyHint("esc")
          }
        }
      }
      .padding(.horizontal, isCompactIOS ? Spacing.sm : Spacing.md)
      .padding(.top, isCompactIOS ? Spacing.sm : Spacing.md)
      .padding(.bottom, isCompactIOS ? Spacing.xs : Spacing.sm)

      Rectangle()
        .fill(Color.panelBorder.opacity(OpacityTier.medium))
        .frame(height: 1)
        .padding(.horizontal, isCompactIOS ? Spacing.xs : Spacing.sm)

      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          if suggestions.isEmpty {
            emptyState
          } else {
            ForEach(Array(suggestions.prefix(8).enumerated()), id: \.element.id) { index, suggestion in
              suggestionRow(suggestion, index: index)
            }
          }
        }
        .padding(isCompactIOS ? Spacing.xs : Spacing.sm)
      }
      .scrollIndicators(.hidden)
      .frame(maxHeight: isCompactIOS ? 188 : 224)
    }
    .background(Color.backgroundSecondary, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .strokeBorder(Color.panelBorder, lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.24), radius: 16, y: 6)
  }

  // MARK: - Helpers

  private var headerIcon: String {
    switch mode {
      case .mention: "at"
      case .skill: "bolt.fill"
      case .command: "slash.circle"
      case .inactive: "magnifyingglass"
    }
  }

  private var headerTitle: String {
    switch mode {
      case .mention: "Files"
      case .skill: "Skills"
      case .command: "Commands"
      case .inactive: "Suggestions"
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

  private func icon(_ kind: ControlDeckCompletionSuggestion.Kind) -> String {
    switch kind {
      case .file: "at"
      case .skill: "bolt.fill"
      case .command: "slash.circle"
    }
  }

  private func tint(_ kind: ControlDeckCompletionSuggestion.Kind) -> Color {
    switch kind {
      case .file: .providerCodex
      case .skill: .accent
      case .command: .statusQuestion
    }
  }

  private func keyHint(_ key: String) -> some View {
    Text(key)
      .font(.system(size: TypeScale.micro, weight: .semibold, design: .monospaced))
      .foregroundStyle(Color.textTertiary)
      .padding(.horizontal, Spacing.xs)
      .padding(.vertical, Spacing.gap)
      .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
          .strokeBorder(Color.panelBorder, lineWidth: 0.5)
      )
  }

  private func suggestionRow(_ suggestion: ControlDeckCompletionSuggestion, index: Int) -> some View {
    let isSelected = index == selectedIndex

    return Button { onSelect(suggestion) } label: {
      HStack(spacing: Spacing.sm) {
        ZStack {
          RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            .fill(tint(suggestion.kind).opacity(isSelected ? OpacityTier.medium : OpacityTier.light))
          Image(systemName: icon(suggestion.kind))
            .font(.system(size: isCompactIOS ? TypeScale.mini : TypeScale.caption, weight: .bold))
            .foregroundStyle(tint(suggestion.kind))
        }
        .frame(width: isCompactIOS ? 24 : 28, height: isCompactIOS ? 24 : 28)

        VStack(alignment: .leading, spacing: Spacing.gap) {
          Text(suggestion.title)
            .font(.system(size: isCompactIOS ? TypeScale.caption : TypeScale.body, weight: .semibold))
            .foregroundStyle(Color.textPrimary)
            .lineLimit(1)

          if let subtitle = suggestion.subtitle, !subtitle.isEmpty {
            Text(subtitle)
              .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
              .foregroundStyle(isSelected ? Color.textSecondary : Color.textTertiary)
              .lineLimit(1)
          }
        }

        Spacer(minLength: 0)

        if isSelected {
          HStack(spacing: Spacing.xxs) {
            Image(systemName: "arrow.turn.down.left")
              .font(.system(size: TypeScale.micro, weight: .bold))
            Text("Insert")
              .font(.system(size: TypeScale.micro, weight: .semibold))
          }
          .foregroundStyle(Color.textSecondary)
        }
      }
      .padding(.horizontal, isCompactIOS ? Spacing.sm : Spacing.md)
      .padding(.vertical, isCompactIOS ? Spacing.sm_ : Spacing.sm)
      .background(
        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
          .fill(isSelected ? headerTint.opacity(OpacityTier.light) : Color.backgroundPrimary)
      )
      .overlay(
        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
          .strokeBorder(
            isSelected ? headerTint.opacity(OpacityTier.medium) : Color.panelBorder.opacity(0.55),
            lineWidth: 1
          )
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private var emptyState: some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: "sparkles")
        .font(.system(size: TypeScale.caption, weight: .semibold))
        .foregroundStyle(Color.textQuaternary)

      Text("No matches yet")
        .font(.system(size: TypeScale.body, weight: .medium))
        .foregroundStyle(Color.textSecondary)
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.backgroundPrimary, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .strokeBorder(Color.panelBorder.opacity(0.55), lineWidth: 1)
    )
  }
}
