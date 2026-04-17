import SwiftUI

struct ControlDeckCompletionPanel: View {
  let mode: ControlDeckCompletionMode
  let suggestions: [ControlDeckCompletionSuggestion]
  let selectedIndex: Int
  let onSelect: (ControlDeckCompletionSuggestion) -> Void

  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  private var isCompact: Bool {
    horizontalSizeClass == .compact
  }

  private var rowHeight: CGFloat { 36 }

  private var visibleRowCount: Int {
    let cap = isCompact ? 5 : 8
    return min(max(suggestions.count, 1), cap)
  }

  private var listMaxHeight: CGFloat {
    CGFloat(visibleRowCount) * rowHeight
  }

  private var selectedSuggestion: ControlDeckCompletionSuggestion? {
    suggestions.indices.contains(selectedIndex) ? suggestions[selectedIndex] : nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      divider
      list
      if let selected = selectedSuggestion, let desc = selected.subtitle, !desc.isEmpty {
        divider
        detailFooter(desc)
      }
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

  // MARK: - Header

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
          .foregroundStyle(Color.textQuaternary)
      }

      Spacer(minLength: 0)

      if !isCompact {
        HStack(spacing: Spacing.sm_) {
          keyHint("↑↓", label: "move")
          keyHint("tab", label: "insert")
          keyHint("esc", label: "dismiss")
        }
      }
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.xs)
  }

  private func keyHint(_ key: String, label: String) -> some View {
    HStack(spacing: Spacing.gap) {
      Text(key)
        .font(.system(size: TypeScale.micro, weight: .semibold, design: .monospaced))
        .foregroundStyle(Color.textTertiary)
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, 2)
        .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous))

      Text(label)
        .font(.system(size: TypeScale.micro, weight: .medium))
        .foregroundStyle(Color.textQuaternary)
    }
  }

  // MARK: - List

  private var list: some View {
    Group {
      if suggestions.isEmpty {
        emptyState
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                suggestionRow(suggestion, index: index)
                  .id(index)
              }
            }
            .padding(.horizontal, Spacing.xxs)
            .padding(.vertical, Spacing.xxs)
          }
          .scrollIndicators(.hidden)
          .frame(minHeight: listMaxHeight, maxHeight: listMaxHeight, alignment: .top)
          .clipped()
          .onChange(of: selectedIndex) { _, newIndex in
            withAnimation(Motion.snappy) {
              proxy.scrollTo(newIndex, anchor: .center)
            }
          }
        }
      }
    }
  }

  private func suggestionRow(_ suggestion: ControlDeckCompletionSuggestion, index: Int) -> some View {
    let isSelected = index == selectedIndex

    return Button { onSelect(suggestion) } label: {
      HStack(spacing: Spacing.sm_) {
        // Icon
        Image(systemName: icon(for: suggestion.kind))
          .font(.system(size: TypeScale.mini, weight: .bold))
          .foregroundStyle(isSelected ? tint(for: suggestion.kind) : tint(for: suggestion.kind).opacity(OpacityTier.vivid))
          .frame(width: 14)

        // Title with namespace parsing for skills
        titleView(for: suggestion, isSelected: isSelected)

        Spacer(minLength: 0)

        // Tab hint on selected
        if isSelected, !isCompact {
          Text("tab")
            .font(.system(size: TypeScale.micro, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color.textTertiary)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 2)
            .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous))
        }
      }
      .padding(.horizontal, Spacing.sm_)
      .frame(height: rowHeight)
      .background(
        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
          .fill(isSelected ? Color.surfaceSelected : Color.clear)
      )
      .overlay(alignment: .leading) {
        if isSelected {
          RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(tint(for: suggestion.kind))
            .frame(width: 2)
            .padding(.vertical, Spacing.sm_)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  @ViewBuilder
  private func titleView(for suggestion: ControlDeckCompletionSuggestion, isSelected: Bool) -> some View {
    switch suggestion.kind {
    case .skill:
      skillTitle(suggestion.title, isSelected: isSelected)
    case .file:
      fileTitle(suggestion.title, relativePath: suggestion.subtitle, isSelected: isSelected)
    case .command:
      Text(suggestion.title)
        .font(.system(size: TypeScale.caption, weight: isSelected ? .semibold : .medium, design: .monospaced))
        .foregroundStyle(isSelected ? Color.textPrimary : Color.textSecondary)
        .lineLimit(1)
    }
  }

  private func skillTitle(_ name: String, isSelected: Bool) -> some View {
    let parts = name.split(separator: ":", maxSplits: 1)
    let hasNamespace = parts.count == 2

    return HStack(spacing: Spacing.gap) {
      if hasNamespace {
        Text(String(parts[0]))
          .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.textQuaternary)
          .lineLimit(1)

        Text(":")
          .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.textQuaternary.opacity(0.5))

        Text(String(parts[1]))
          .font(.system(size: TypeScale.caption, weight: isSelected ? .semibold : .medium, design: .monospaced))
          .foregroundStyle(isSelected ? Color.textPrimary : Color.textSecondary)
          .lineLimit(1)
      } else {
        Text(name)
          .font(.system(size: TypeScale.caption, weight: isSelected ? .semibold : .medium, design: .monospaced))
          .foregroundStyle(isSelected ? Color.textPrimary : Color.textSecondary)
          .lineLimit(1)
      }
    }
  }

  private func fileTitle(_ name: String, relativePath: String?, isSelected: Bool) -> some View {
    HStack(spacing: Spacing.xs) {
      Text(name)
        .font(.system(size: TypeScale.caption, weight: isSelected ? .semibold : .medium))
        .foregroundStyle(isSelected ? Color.textPrimary : Color.textSecondary)
        .lineLimit(1)

      if let path = relativePath, !path.isEmpty, path != name {
        Text(parentPath(from: path, fileName: name))
          .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.textQuaternary)
          .lineLimit(1)
          .truncationMode(.head)
      }
    }
  }

  private func parentPath(from relativePath: String, fileName: String) -> String {
    let parent = (relativePath as NSString).deletingLastPathComponent
    guard !parent.isEmpty else { return "" }
    return parent
  }

  // MARK: - Detail Footer

  private func detailFooter(_ description: String) -> some View {
    HStack(spacing: Spacing.xs) {
      Text(description)
        .font(.system(size: TypeScale.micro, weight: .medium))
        .foregroundStyle(Color.textTertiary)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)

      Spacer(minLength: 0)
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.sm_)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: - Empty State

  private var emptyState: some View {
    HStack(spacing: Spacing.xs) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: TypeScale.mini, weight: .semibold))
        .foregroundStyle(Color.textQuaternary)

      Text(emptyStateText)
        .font(.system(size: TypeScale.caption, weight: .medium))
        .foregroundStyle(Color.textTertiary)
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.md)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var divider: some View {
    Rectangle()
      .fill(Color.panelBorder.opacity(OpacityTier.medium))
      .frame(height: 1)
  }

  // MARK: - Mode Properties

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
    case .file: "doc.text"
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
