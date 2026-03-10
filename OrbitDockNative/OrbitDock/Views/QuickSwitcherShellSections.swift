import SwiftUI

struct QuickSwitcherSearchBar: View {
  let isCompactLayout: Bool
  @Binding var searchText: String
  @FocusState.Binding var isSearchFocused: Bool
  let onClear: () -> Void
  let onCancel: () -> Void

  var body: some View {
    HStack(spacing: Spacing.sm) {
      HStack(spacing: Spacing.sm) {
        Image(systemName: "magnifyingglass")
          .font(.system(size: TypeScale.body, weight: .medium))
          .foregroundStyle(Color.textTertiary)

        TextField("Search sessions or commands", text: $searchText)
          .textFieldStyle(.plain)
          .font(.system(size: isCompactLayout ? TypeScale.body : TypeScale.subhead))
          .foregroundStyle(Color.textPrimary)
          .focused($isSearchFocused)

        if !searchText.isEmpty {
          Button(action: onClear) {
            Image(systemName: "xmark.circle.fill")
              .font(.system(size: TypeScale.body))
              .foregroundStyle(Color.textQuaternary)
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, isCompactLayout ? Spacing.sm_ : Spacing.sm)
      .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))

      if isCompactLayout {
        Button("Done", action: onCancel)
          .font(.system(size: TypeScale.body, weight: .semibold))
          .foregroundStyle(Color.accent)
      }
    }
    .padding(.horizontal, isCompactLayout ? Spacing.md : Spacing.lg)
    .padding(.vertical, isCompactLayout ? Spacing.sm : Spacing.md)
  }
}

struct QuickSwitcherShell<SearchBar: View, Content: View, EmptyState: View, Footer: View>: View {
  let isCompactLayout: Bool
  let isEmptyState: Bool
  @ViewBuilder let searchBar: () -> SearchBar
  @ViewBuilder let content: () -> Content
  @ViewBuilder let emptyState: () -> EmptyState
  @ViewBuilder let footer: () -> Footer

  var body: some View {
    VStack(spacing: 0) {
      searchBar()

      Divider()
        .foregroundStyle(Color.panelBorder)

      if isEmptyState {
        emptyState()
      } else {
        content()
      }

      if !isCompactLayout {
        footer()
      }
    }
    .frame(maxWidth: isCompactLayout ? .infinity : 720)
    .background {
      if isCompactLayout {
        Color.backgroundSecondary
          .ignoresSafeArea(.container, edges: .bottom)
      } else {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .fill(Color.backgroundSecondary)
      }
    }
    .overlay {
      if !isCompactLayout {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .strokeBorder(Color.panelBorder, lineWidth: 1)
      }
    }
    .clipShape(
      isCompactLayout
        ? AnyShape(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
        : AnyShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    )
    .themeShadow(Shadow.lg)
    .padding(.horizontal, isCompactLayout ? Spacing.sm_ : 0)
  }
}

struct QuickSwitcherCommandsSection<Row: View>: View {
  let commands: [QuickSwitcherCommand]
  let activeSession: Session?
  let isCompactLayout: Bool
  @ViewBuilder let row: (QuickSwitcherCommand, Int) -> Row

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      sectionHeader(
        title: activeSession == nil ? "COMMANDS" : "COMMANDS FOR \(activeSession?.displayName.uppercased() ?? "")",
        icon: "command"
      )

      ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
        row(command, index)
          .id("row-\(index)")
      }
    }
  }

  @ViewBuilder
  private func sectionHeader(title: String, icon: String) -> some View {
    HStack(spacing: Spacing.xs) {
      Image(systemName: icon)
        .font(.system(size: isCompactLayout ? TypeScale.micro : TypeScale.meta, weight: .semibold))
      Text(title)
        .font(.system(size: isCompactLayout ? TypeScale.micro : TypeScale.meta, weight: .bold, design: .rounded))
        .tracking(0.8)
    }
    .foregroundStyle(Color.textTertiary)
    .padding(.horizontal, isCompactLayout ? Spacing.lg_ : Spacing.section)
    .padding(.top, isCompactLayout ? Spacing.sm_ : Spacing.sm)
    .padding(.bottom, isCompactLayout ? Spacing.xs : Spacing.sm)
  }
}

struct QuickSwitcherActiveSessionsSection<Row: View>: View {
  let sessions: [Session]
  let isCompactLayout: Bool
  let sessionStartIndex: Int
  @ViewBuilder let row: (Session, Int) -> Row

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      sectionHeader(title: "ACTIVE SESSIONS", icon: "bolt.fill", tint: .statusWorking)

      ForEach(Array(sessions.enumerated()), id: \.element.id) { offset, session in
        row(session, sessionStartIndex + offset)
          .id("row-\(sessionStartIndex + offset)")
      }
    }
  }

  @ViewBuilder
  private func sectionHeader(title: String, icon: String, tint: Color) -> some View {
    HStack(spacing: Spacing.xs) {
      Image(systemName: icon)
        .font(.system(size: isCompactLayout ? TypeScale.micro : TypeScale.meta, weight: .semibold))
      Text(title)
        .font(.system(size: isCompactLayout ? TypeScale.micro : TypeScale.meta, weight: .bold, design: .rounded))
        .tracking(0.8)
    }
    .foregroundStyle(tint)
    .padding(.horizontal, isCompactLayout ? Spacing.lg_ : Spacing.section)
    .padding(.top, isCompactLayout ? Spacing.sm_ : Spacing.sm)
    .padding(.bottom, isCompactLayout ? Spacing.xs : Spacing.sm)
  }
}

struct QuickSwitcherRecentSessionsSection<Row: View>: View {
  let sessions: [Session]
  let isCompactLayout: Bool
  let searchQuery: String
  let isExpanded: Bool
  let shouldShowSessions: Bool
  let sessionStartIndex: Int
  let activeSessionCount: Int
  let onToggleExpanded: () -> Void
  @ViewBuilder let row: (Session, Int) -> Row

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button(action: onToggleExpanded) {
        HStack(spacing: Spacing.xs) {
          Image(systemName: isExpanded || !searchQuery.isEmpty ? "chevron.down" : "chevron.right")
            .font(.system(size: isCompactLayout ? TypeScale.micro : TypeScale.meta, weight: .semibold))
          Text("RECENT SESSIONS")
            .font(.system(size: isCompactLayout ? TypeScale.micro : TypeScale.meta, weight: .bold, design: .rounded))
            .tracking(0.8)
          Spacer()
          Text("\(sessions.count)")
            .font(.system(size: TypeScale.micro, weight: .bold, design: .rounded))
            .foregroundStyle(Color.textTertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.surfaceHover.opacity(0.55), in: Capsule())
        }
        .foregroundStyle(Color.textTertiary)
        .padding(.horizontal, isCompactLayout ? Spacing.lg_ : Spacing.section)
        .padding(.top, isCompactLayout ? Spacing.sm_ : Spacing.sm)
        .padding(.bottom, isCompactLayout ? Spacing.xs : Spacing.sm)
      }
      .buttonStyle(.plain)

      if shouldShowSessions {
        ForEach(Array(sessions.enumerated()), id: \.element.id) { offset, session in
          let index = sessionStartIndex + activeSessionCount + offset
          row(session, index)
            .id("row-\(index)")
        }
      }
    }
  }
}

struct QuickSwitcherResultsShell<Content: View>: View {
  let isCompactLayout: Bool
  let selectedIndex: Int
  @ViewBuilder let content: () -> Content

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 0) {
          content()
        }
        .padding(.vertical, isCompactLayout ? Spacing.xs : Spacing.sm)
      }
      .frame(maxHeight: isCompactLayout ? 560 : 620)
      .onChange(of: selectedIndex) { _, newIndex in
        proxy.scrollTo("row-\(newIndex)", anchor: .center)
      }
    }
  }
}
