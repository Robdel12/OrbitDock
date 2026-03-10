import SwiftUI

struct QuickSwitcherSearchBar: View {
  let isCompactLayout: Bool
  @Binding var searchText: String
  @FocusState.Binding var isSearchFocused: Bool
  let onClear: () -> Void
  let onCancel: () -> Void

  var body: some View {
    HStack(spacing: isCompactLayout ? Spacing.md_ : Spacing.lg_) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: isCompactLayout ? TypeScale.large : TypeScale.thinkingHeading1, weight: .medium))
        .foregroundStyle(Color.textTertiary)
        .frame(width: isCompactLayout ? Spacing.section : Spacing.xl)

      TextField(
        isCompactLayout ? "Search sessions..." : "Search sessions and commands...",
        text: $searchText
      )
      .textFieldStyle(.plain)
      .font(.system(size: isCompactLayout ? TypeScale.large : 17))
      .focused($isSearchFocused)

      if !searchText.isEmpty {
        Button(action: onClear) {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: isCompactLayout ? TypeScale.thinkingHeading1 : TypeScale.large))
            .foregroundStyle(Color.textQuaternary)
        }
        .buttonStyle(.plain)
      }

      if isCompactLayout {
        Button(action: onCancel) {
          Text("Cancel")
            .font(.system(size: TypeScale.reading, weight: .medium))
            .foregroundStyle(Color.accent)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, isCompactLayout ? Spacing.lg_ : Spacing.section)
    .padding(.vertical, isCompactLayout ? Spacing.md : Spacing.lg_)
    .frame(minHeight: isCompactLayout ? nil : 40)
  }
}

struct QuickSwitcherActiveSessionsSection<RowContent: View>: View {
  let sessions: [Session]
  let isCompactLayout: Bool
  let sessionStartIndex: Int
  let row: (Session, Int) -> RowContent

  var body: some View {
    VStack(alignment: .leading, spacing: isCompactLayout ? Spacing.xxs : Spacing.xs) {
      HStack(spacing: isCompactLayout ? Spacing.sm_ : Spacing.sm) {
        Image(systemName: "cpu")
          .font(.system(size: isCompactLayout ? TypeScale.micro : TypeScale.meta, weight: .semibold))
          .foregroundStyle(Color.accent)

        Text("ACTIVE")
          .font(.system(size: isCompactLayout ? TypeScale.micro : TypeScale.meta, weight: .bold, design: .rounded))
          .foregroundStyle(Color.accent)
          .tracking(0.8)

        Text("\(sessions.count)")
          .font(.system(size: isCompactLayout ? TypeScale.mini : TypeScale.micro, weight: .bold, design: .rounded))
          .foregroundStyle(Color.accent)
          .padding(.horizontal, Spacing.sm_)
          .padding(.vertical, Spacing.xxs)
          .background(Color.accent.opacity(0.15), in: Capsule())
      }
      .padding(.horizontal, isCompactLayout ? Spacing.lg_ : Spacing.section)
      .padding(.top, isCompactLayout ? Spacing.md_ : Spacing.lg)
      .padding(.bottom, isCompactLayout ? Spacing.xs : Spacing.sm)

      ForEach(Array(sessions.enumerated()), id: \.element.scopedID) { index, session in
        row(session, sessionStartIndex + index)
          .id("row-\(sessionStartIndex + index)")
      }
    }
  }
}

struct QuickSwitcherRecentSessionsSection<RowContent: View>: View {
  let sessions: [Session]
  let isCompactLayout: Bool
  let searchQuery: String
  let isExpanded: Bool
  let shouldShowSessions: Bool
  let sessionStartIndex: Int
  let activeSessionCount: Int
  let onToggleExpanded: () -> Void
  let row: (Session, Int) -> RowContent

  var body: some View {
    let isSearching = !searchQuery.isEmpty

    return VStack(alignment: .leading, spacing: isCompactLayout ? Spacing.xxs : Spacing.xs) {
      Button(action: onToggleExpanded) {
        HStack(spacing: isCompactLayout ? Spacing.sm_ : Spacing.sm) {
          if !isSearching {
            Image(systemName: "chevron.right")
              .font(.system(size: isCompactLayout ? TypeScale.mini : TypeScale.micro, weight: .semibold))
              .foregroundStyle(Color.textQuaternary)
              .rotationEffect(.degrees(isExpanded ? 90 : 0))
          }

          Image(systemName: "clock")
            .font(.system(size: isCompactLayout ? TypeScale.micro : TypeScale.meta, weight: .semibold))
            .foregroundStyle(Color.statusEnded)

          Text("RECENT")
            .font(.system(size: isCompactLayout ? TypeScale.micro : TypeScale.meta, weight: .bold, design: .rounded))
            .foregroundStyle(Color.statusEnded)
            .tracking(0.8)

          Text("\(sessions.count)")
            .font(.system(size: isCompactLayout ? TypeScale.mini : TypeScale.micro, weight: .bold, design: .rounded))
            .foregroundStyle(Color.statusEnded)
            .padding(.horizontal, Spacing.sm_)
            .padding(.vertical, Spacing.xxs)
            .background(Color.statusEnded.opacity(0.15), in: Capsule())

          Spacer()
        }
        .padding(.horizontal, isCompactLayout ? Spacing.lg_ : Spacing.section)
        .padding(.top, isCompactLayout ? Spacing.md_ : Spacing.lg)
        .padding(.bottom, isCompactLayout ? Spacing.xs : Spacing.sm)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(isSearching)

      if shouldShowSessions {
        ForEach(Array(sessions.enumerated()), id: \.element.scopedID) { index, session in
          let globalIndex = sessionStartIndex + activeSessionCount + index
          row(session, globalIndex)
            .id("row-\(globalIndex)")
        }
      }
    }
  }
}

struct QuickSwitcherCommandsSection<RowContent: View>: View {
  let commands: [QuickSwitcherCommand]
  let activeSession: Session?
  let isCompactLayout: Bool
  let row: (QuickSwitcherCommand, Int) -> RowContent

  var body: some View {
    VStack(alignment: .leading, spacing: isCompactLayout ? Spacing.xxs : Spacing.xs) {
      HStack(spacing: isCompactLayout ? Spacing.sm_ : Spacing.sm) {
        Image(systemName: "command")
          .font(.system(size: isCompactLayout ? TypeScale.micro : TypeScale.meta, weight: .semibold))
          .foregroundStyle(Color.accent)

        Text("COMMANDS")
          .font(.system(size: isCompactLayout ? TypeScale.micro : TypeScale.meta, weight: .bold, design: .rounded))
          .foregroundStyle(Color.accent)
          .tracking(0.8)

        if let activeSession {
          Text("→")
            .font(.system(size: isCompactLayout ? TypeScale.mini : TypeScale.micro))
            .foregroundStyle(Color.textQuaternary)

          Text(activeSession.displayName)
            .font(.system(size: isCompactLayout ? TypeScale.micro : TypeScale.meta, weight: .medium))
            .foregroundStyle(Color.textSecondary)
            .lineLimit(1)
        }
      }
      .padding(.horizontal, isCompactLayout ? Spacing.lg_ : Spacing.section)
      .padding(.top, isCompactLayout ? Spacing.sm_ : Spacing.sm)
      .padding(.bottom, isCompactLayout ? Spacing.xxs : Spacing.xs)

      ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
        row(command, index)
          .id("row-\(index)")
      }

      Rectangle()
        .fill(Color.panelBorder)
        .frame(height: 1)
        .padding(.horizontal, Spacing.section)
        .padding(.vertical, Spacing.sm)
    }
  }
}
