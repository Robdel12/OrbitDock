//
//  QuickSwitcher.swift
//  OrbitDock
//
//  Command palette for switching agents and executing actions (⌘K)
//  - No prefix: Search sessions
//  - ">" prefix: Search commands
//  - "new claude" / "new codex": Quick launch mode with recent projects
//

import SwiftUI

// MARK: - Quick Launch Provider

enum QuickLaunchProvider: Equatable {
  case claude
  case codex

  var displayName: String {
    switch self {
      case .claude: "Claude"
      case .codex: "Codex"
    }
  }

  var color: Color {
    switch self {
      case .claude: Color.providerClaude
      case .codex: Color.providerCodex
    }
  }

  var icon: String {
    switch self {
      case .claude: "sparkles"
      case .codex: "terminal.fill"
    }
  }
}

// MARK: - Command Definition

struct QuickCommand: Identifiable {
  let id: String
  let name: String
  let icon: String
  let shortcut: String?
  let requiresSession: Bool
  let action: (Session?) -> Void

  static func sessionCommands(
    onRename: @escaping (Session) -> Void,
    onFocus: @escaping (Session) -> Void,
    onOpenFinder: @escaping (Session) -> Void,
    onCopyResume: @escaping (Session) -> Void,
    onClose: @escaping (Session) -> Void
  ) -> [QuickCommand] {
    [
      QuickCommand(
        id: "rename",
        name: "Rename Session",
        icon: "pencil",
        shortcut: "⌘R",
        requiresSession: true,
        action: { session in if let s = session { onRename(s) } }
      ),
      QuickCommand(
        id: "focus",
        name: "Focus Terminal",
        icon: "terminal",
        shortcut: nil,
        requiresSession: true,
        action: { session in if let s = session { onFocus(s) } }
      ),
      QuickCommand(
        id: "finder",
        name: "Open in Finder",
        icon: "folder",
        shortcut: nil,
        requiresSession: true,
        action: { session in if let s = session { onOpenFinder(s) } }
      ),
      QuickCommand(
        id: "copy",
        name: "Copy Resume Command",
        icon: "doc.on.doc",
        shortcut: nil,
        requiresSession: true,
        action: { session in if let s = session { onCopyResume(s) } }
      ),
      QuickCommand(
        id: "close",
        name: "Close Session",
        icon: "xmark.circle",
        shortcut: nil,
        requiresSession: true,
        action: { session in if let s = session { onClose(s) } }
      ),
    ]
  }
}

// MARK: - Quick Switcher

struct QuickSwitcher: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(ServerAppState.self) private var serverState
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry
  @Environment(AppRouter.self) private var router
  let sessions: [Session]

  // Quick launch callbacks
  let onQuickLaunchClaude: ((String) -> Void)?
  let onQuickLaunchCodex: ((String) -> Void)?

  @State private var searchText = ""
  @State private var selectedIndex = 0
  @State private var hoveredIndex: Int?
  @State private var renamingSession: Session?
  @State private var renameText = ""
  @State private var targetSession: Session? // Session that commands will act on
  @State private var isRecentExpanded = false // Recent section collapsed by default
  @FocusState private var isSearchFocused: Bool

  // Quick launch state
  @State private var quickLaunchMode: QuickLaunchProvider?
  @State private var recentProjects: [ServerRecentProject] = []
  @State private var isLoadingProjects = false
  @State private var recentProjectsRequestId = UUID()

  /// The session currently being viewed (for commands to act on)
  private var currentSession: Session? {
    if let id = router.selectedScopedID {
      return sessions.first { $0.scopedID == id }
    }
    return nil
  }

  // MARK: - Search

  private var isCompactLayout: Bool {
    #if os(iOS)
      horizontalSizeClass == .compact
    #else
      false
    #endif
  }

  private var searchQuery: String {
    searchText.trimmingCharacters(in: .whitespaces).lowercased()
  }

  // MARK: - Commands

  private var commands: [QuickCommand] {
    // Global commands (no session required)
    var allCommands: [QuickCommand] = [
      QuickCommand(
        id: "dashboard",
        name: "Go to Dashboard",
        icon: "square.grid.2x2",
        shortcut: "⌘0",
        requiresSession: false,
        action: { _ in
          router.goToDashboard()
          router.closeQuickSwitcher()
        }
      ),
      QuickCommand(
        id: "new-claude",
        name: "New Claude Session",
        icon: "plus.circle.fill",
        shortcut: nil,
        requiresSession: false,
        action: { _ in
          router.showNewClaudeSheet = true
          router.closeQuickSwitcher()
        }
      ),
      QuickCommand(
        id: "new-codex",
        name: "New Codex Session",
        icon: "plus.circle.fill",
        shortcut: nil,
        requiresSession: false,
        action: { _ in
          router.showNewCodexSheet = true
          router.closeQuickSwitcher()
        }
      ),
    ]

    // Session-specific commands
    allCommands += QuickCommand.sessionCommands(
      onRename: { session in
        renameText = session.customName ?? ""
        renamingSession = session
      },
      onFocus: { [self] session in
        focusTerminal(for: session)
        router.closeQuickSwitcher()
      },
      onOpenFinder: { session in
        _ = Platform.services.revealInFileBrowser(session.projectPath)
        router.closeQuickSwitcher()
      },
      onCopyResume: { session in
        let command = "claude --resume \(session.id)"
        Platform.services.copyToClipboard(command)
        router.closeQuickSwitcher()
      },
      onClose: { [self] session in
        appState(for: session).endSession(session.id)
        router.closeQuickSwitcher()
      }
    )

    return allCommands
  }

  private var filteredCommands: [QuickCommand] {
    guard !searchQuery.isEmpty else { return [] }
    return commands.filter { $0.name.lowercased().contains(searchQuery) }
  }

  // MARK: - Sessions

  private var filteredSessions: [Session] {
    guard !searchQuery.isEmpty else { return sessions }
    return sessions.filter {
      $0.displayName.localizedCaseInsensitiveContains(searchQuery) ||
        $0.projectPath.localizedCaseInsensitiveContains(searchQuery) ||
        ($0.summary ?? "").localizedCaseInsensitiveContains(searchQuery) ||
        ($0.customName ?? "").localizedCaseInsensitiveContains(searchQuery) ||
        ($0.branch ?? "").localizedCaseInsensitiveContains(searchQuery)
    }
  }

  /// All active sessions sorted by start time (newest first)
  private var activeSessions: [Session] {
    filteredSessions
      .filter(\.isActive)
      .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
  }

  /// Recent ended sessions
  private var recentSessions: [Session] {
    filteredSessions
      .filter { !$0.isActive }
      .sorted { ($0.endedAt ?? .distantPast) > ($1.endedAt ?? .distantPast) }
      .prefix(20)
      .map { $0 }
  }

  /// Flat list for keyboard navigation (matches display order)
  /// Only includes recent sessions if searching or if the section is expanded
  private var allVisibleSessions: [Session] {
    let showRecent = !searchQuery.isEmpty || isRecentExpanded
    return showRecent ? activeSessions + recentSessions : activeSessions
  }

  // Total items for navigation
  // Order: Commands (if searching) → Dashboard → Sessions
  // In quick launch mode: just recent projects
  private var totalItems: Int {
    if quickLaunchMode != nil {
      return recentProjects.count
    }
    return filteredCommands.count + 1 + allVisibleSessions.count // commands + dashboard + sessions
  }

  var body: some View {
    mainContent
      .onAppear {
        selectedIndex = 0
        focusSearchField()
      }
      .modifier(KeyboardNavigationModifier(
        onMoveUp: { moveSelection(by: -1) },
        onMoveDown: { moveSelection(by: 1) },
        onMoveToFirst: { selectedIndex = 0 },
        onMoveToLast: {
          if totalItems > 0 { selectedIndex = totalItems - 1 }
        },
        onSelect: { selectCurrent() },
        onRename: { renameCurrentSelection() },
        onShiftSelect: quickLaunchMode != nil ? { openFullSheet() } : nil
      ))
      .onChange(of: searchText) { oldValue, newValue in
        // When starting to type, capture the current session as target
        if oldValue.isEmpty, !newValue.isEmpty {
          let sessionIndex = selectedIndex - sessionStartIndex
          if sessionIndex >= 0, sessionIndex < allVisibleSessions.count {
            targetSession = allVisibleSessions[sessionIndex]
          } else {
            targetSession = allVisibleSessions.first
          }
        } else if newValue.isEmpty {
          targetSession = nil
        }
        selectedIndex = 0
        hoveredIndex = nil

        // Detect quick launch mode
        let query = newValue.lowercased().trimmingCharacters(in: .whitespaces)
        let oldMode = quickLaunchMode

        if query.hasPrefix("new c") || query.hasPrefix("claude") || query == "nc" {
          quickLaunchMode = .claude
        } else if query.hasPrefix("new o") || query.hasPrefix("new codex") || query
          .hasPrefix("codex") || query == "no"
        {
          quickLaunchMode = .codex
        } else if query.hasPrefix("new") || query == "n" {
          // Just "new" - show both options, not quick launch mode
          quickLaunchMode = nil
        } else {
          quickLaunchMode = nil
        }

        // Load recent projects when entering quick launch mode
        if quickLaunchMode != nil, oldMode == nil {
          loadRecentProjects()
        }
      }
      .sheet(item: $renamingSession) { session in
        RenameSessionSheet(
          session: session,
          initialText: renameText,
          onSave: { newName in
            let name = newName.isEmpty ? nil : newName
            appState(for: session).renameSession(sessionId: session.id, name: name)
            renamingSession = nil
          },
          onCancel: {
            renamingSession = nil
          }
        )
      }
  }

  private var mainContent: some View {
    VStack(spacing: 0) {
      searchBar

      Divider()
        .foregroundStyle(Color.panelBorder)

      if allVisibleSessions.isEmpty, filteredCommands.isEmpty, !searchQuery.isEmpty {
        emptyState
      } else {
        resultsView
      }

      if !isCompactLayout {
        footerHint
      }
    }
    .frame(maxWidth: isCompactLayout ? .infinity : 720)
    .padding(.horizontal, isCompactLayout ? 0 : 0)
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
    .shadow(
      color: .black.opacity(isCompactLayout ? 0.3 : 0.5),
      radius: isCompactLayout ? 20 : 40,
      x: 0,
      y: isCompactLayout ? 10 : 20
    )
    .padding(.horizontal, isCompactLayout ? 6 : 0)
  }

  private func commandRow(command: QuickCommand, index: Int) -> some View {
    let iconSize: CGFloat = isCompactLayout ? 28 : 32

    return Button {
      executeCommand(command)
    } label: {
      HStack(spacing: isCompactLayout ? 10 : 14) {
        // Icon in colored container
        ZStack {
          RoundedRectangle(cornerRadius: isCompactLayout ? 7 : 8, style: .continuous)
            .fill(Color.accent.opacity(0.1))
            .frame(width: iconSize, height: iconSize)

          Image(systemName: command.icon)
            .font(.system(size: isCompactLayout ? 13 : 14, weight: .medium))
            .foregroundStyle(Color.accent.opacity(0.8))
        }

        VStack(alignment: .leading, spacing: 2) {
          Text(command.name)
            .font(.system(size: isCompactLayout ? 15 : 14, weight: .medium))
            .foregroundStyle(.primary)

          if command.requiresSession {
            Text("Applies to selected session")
              .font(.system(size: isCompactLayout ? 12 : 11))
              .foregroundStyle(Color.textTertiary)
          }
        }

        Spacer()

        if !isCompactLayout, let shortcut = command.shortcut {
          Text(shortcut)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
      }
      .padding(.horizontal, isCompactLayout ? 12 : 16)
      .padding(.vertical, isCompactLayout ? 10 : 12)
      .background(
        QuickSwitcherRowBackground(
          isSelected: selectedIndex == index,
          isHovered: hoveredIndex == index
        )
      )
      .padding(.horizontal, isCompactLayout ? 4 : 8)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovered in
      guard !isCompactLayout else { return }
      hoveredIndex = isHovered ? index : nil
    }
  }

  private func executeCommand(_ command: QuickCommand) {
    if command.requiresSession {
      // Use current session (from ContentView), or target (from navigation), or first visible
      guard let session = currentSession ?? targetSession ?? allVisibleSessions.first else { return }
      command.action(session)
    } else {
      command.action(nil)
    }
  }

  // MARK: - Search Bar

  private var searchBar: some View {
    HStack(spacing: isCompactLayout ? 10 : 14) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: isCompactLayout ? 16 : 18, weight: .medium))
        .foregroundStyle(Color.textTertiary)
        .frame(width: isCompactLayout ? 20 : 24)

      TextField(
        isCompactLayout ? "Search sessions..." : "Search sessions and commands...",
        text: $searchText
      )
      .textFieldStyle(.plain)
      .font(.system(size: isCompactLayout ? 16 : 17))
      .focused($isSearchFocused)

      if !searchText.isEmpty {
        Button {
          searchText = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: isCompactLayout ? 18 : 16))
            .foregroundStyle(Color.textQuaternary)
        }
        .buttonStyle(.plain)
      }

      if isCompactLayout {
        Button {
          router.closeQuickSwitcher()
        } label: {
          Text("Cancel")
            .font(.system(size: TypeScale.reading, weight: .medium))
            .foregroundStyle(Color.accent)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, isCompactLayout ? 14 : 20)
    .padding(.vertical, isCompactLayout ? 12 : 14)
    .frame(minHeight: isCompactLayout ? nil : 40)
  }

  // MARK: - Results View

  /// Index offset: commands come first, then dashboard, then sessions
  private var commandCount: Int {
    filteredCommands.count
  }

  private var dashboardIndex: Int {
    commandCount
  }

  private var sessionStartIndex: Int {
    commandCount + 1
  }

  private var resultsView: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 0) {
          if quickLaunchMode != nil {
            // Quick launch mode: show recent projects
            quickLaunchSection
          } else {
            // Normal mode: commands, dashboard, sessions
            // Commands section (when searching)
            if !filteredCommands.isEmpty {
              commandsSection
            }

            // Dashboard row
            dashboardRow
              .id("row-\(dashboardIndex)")

            // Active sessions - flat list sorted by start time (matches dashboard)
            if !activeSessions.isEmpty {
              activeSessionsSection
            }

            // Recent ended sessions
            if !recentSessions.isEmpty {
              recentSessionsSection
            }
          }
        }
        .padding(.vertical, isCompactLayout ? 4 : 8)
      }
      .frame(maxHeight: isCompactLayout ? 560 : 620)
      .onChange(of: selectedIndex) { _, newIndex in
        proxy.scrollTo("row-\(newIndex)", anchor: .center)
      }
    }
  }

  // MARK: - Quick Launch Section

  private var quickLaunchSection: some View {
    let provider = quickLaunchMode!

    return VStack(alignment: .leading, spacing: isCompactLayout ? 2 : 4) {
      // Header
      HStack(spacing: isCompactLayout ? 6 : 8) {
        Image(systemName: provider.icon)
          .font(.system(size: isCompactLayout ? 10 : 11, weight: .semibold))
          .foregroundStyle(provider.color)

        Text("NEW \(provider.displayName.uppercased()) SESSION")
          .font(.system(size: isCompactLayout ? 10 : 11, weight: .bold, design: .rounded))
          .foregroundStyle(provider.color)
          .tracking(0.8)

        Spacer()

        // Full sheet option
        Button {
          openFullSheet()
        } label: {
          HStack(spacing: 4) {
            Text("Full Options")
              .font(.system(size: isCompactLayout ? 11 : 10, weight: .medium))
            Image(systemName: "arrow.up.right")
              .font(.system(size: isCompactLayout ? 9 : 8, weight: .semibold))
          }
          .foregroundStyle(Color.textTertiary)
          .padding(.horizontal, isCompactLayout ? 10 : 8)
          .padding(.vertical, isCompactLayout ? 5 : 4)
          .background(Color.surfaceHover, in: Capsule())
        }
        .buttonStyle(.plain)
      }
      .padding(.horizontal, isCompactLayout ? 14 : 20)
      .padding(.top, isCompactLayout ? 6 : 8)
      .padding(.bottom, isCompactLayout ? 4 : 8)

      // Loading state
      if isLoadingProjects {
        HStack {
          Spacer()
          ProgressView()
            .controlSize(.small)
          Spacer()
        }
        .padding(.vertical, isCompactLayout ? 20 : 24)
      } else if recentProjects.isEmpty {
        // Empty state
        VStack(spacing: isCompactLayout ? 6 : 8) {
          Image(systemName: "folder.badge.plus")
            .font(.system(size: isCompactLayout ? 20 : 24))
            .foregroundStyle(Color.textQuaternary)
          Text("No recent projects")
            .font(.system(size: isCompactLayout ? 14 : 13))
            .foregroundStyle(Color.textTertiary)
          Text("Use Full Options to browse directories")
            .font(.system(size: isCompactLayout ? 12 : 11))
            .foregroundStyle(Color.textQuaternary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, isCompactLayout ? 20 : 24)
      } else {
        // Recent projects list
        ForEach(Array(recentProjects.enumerated()), id: \.element.id) { index, project in
          quickLaunchProjectRow(project: project, index: index, provider: provider)
            .id("row-\(index)")
        }
      }
    }
  }

  private func quickLaunchProjectRow(
    project: ServerRecentProject,
    index: Int,
    provider: QuickLaunchProvider
  ) -> some View {
    let iconSize: CGFloat = isCompactLayout ? 32 : 36

    return Button {
      quickLaunchSession(path: project.path)
    } label: {
      HStack(spacing: isCompactLayout ? 10 : 14) {
        // Folder icon with provider color
        ZStack {
          RoundedRectangle(cornerRadius: isCompactLayout ? 7 : 8, style: .continuous)
            .fill(provider.color.opacity(0.1))
            .frame(width: iconSize, height: iconSize)

          Image(systemName: "folder.fill")
            .font(.system(size: isCompactLayout ? 14 : 15, weight: .medium))
            .foregroundStyle(provider.color.opacity(0.8))
        }

        VStack(alignment: .leading, spacing: isCompactLayout ? 2 : 3) {
          Text(URL(fileURLWithPath: project.path).lastPathComponent)
            .font(.system(size: isCompactLayout ? 15 : 14, weight: .semibold))
            .foregroundStyle(Color.textPrimary)

          Text(displayPath(project.path))
            .font(.system(size: isCompactLayout ? 12 : 11, design: .monospaced))
            .foregroundStyle(Color.textTertiary)
            .lineLimit(1)
            .truncationMode(.middle)
        }

        Spacer(minLength: 4)

        // Session count badge
        HStack(spacing: 4) {
          Image(systemName: "clock")
            .font(.system(size: isCompactLayout ? 10 : 9))
          Text("\(project.sessionCount)")
            .font(.system(size: isCompactLayout ? 11 : 10, weight: .medium))
        }
        .foregroundStyle(Color.textQuaternary)
        .padding(.horizontal, isCompactLayout ? 10 : 8)
        .padding(.vertical, isCompactLayout ? 5 : 4)
        .background(Color.surfaceHover, in: Capsule())
      }
      .padding(.horizontal, isCompactLayout ? 12 : 16)
      .padding(.vertical, isCompactLayout ? 10 : 10)
      .background(
        QuickSwitcherRowBackground(
          isSelected: selectedIndex == index,
          isHovered: hoveredIndex == index
        )
      )
      .padding(.horizontal, isCompactLayout ? 4 : 8)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovered in
      guard !isCompactLayout else { return }
      hoveredIndex = isHovered ? index : nil
    }
  }

  private func displayPath(_ path: String) -> String {
    if path.hasPrefix("/Users/") {
      let parts = path.split(separator: "/", maxSplits: 3)
      if parts.count >= 2 {
        return "~/" + (parts.count > 2 ? String(parts[2...].joined(separator: "/")) : "")
      }
    }
    return path.isEmpty ? "~" : path
  }

  // MARK: - Active Sessions Section

  private var activeSessionsSection: some View {
    VStack(alignment: .leading, spacing: isCompactLayout ? 2 : 4) {
      // Section Header
      HStack(spacing: isCompactLayout ? 6 : 8) {
        Image(systemName: "cpu")
          .font(.system(size: isCompactLayout ? 10 : 11, weight: .semibold))
          .foregroundStyle(Color.accent)

        Text("ACTIVE")
          .font(.system(size: isCompactLayout ? 10 : 11, weight: .bold, design: .rounded))
          .foregroundStyle(Color.accent)
          .tracking(0.8)

        // Count badge
        Text("\(activeSessions.count)")
          .font(.system(size: isCompactLayout ? 9 : 10, weight: .bold, design: .rounded))
          .foregroundStyle(Color.accent)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(Color.accent.opacity(0.15), in: Capsule())
      }
      .padding(.horizontal, isCompactLayout ? 14 : 20)
      .padding(.top, isCompactLayout ? 10 : 16)
      .padding(.bottom, isCompactLayout ? 4 : 8)

      // Session Rows
      ForEach(Array(activeSessions.enumerated()), id: \.element.scopedID) { index, session in
        let globalIndex = sessionStartIndex + index
        switcherRow(session: session, index: globalIndex)
          .id("row-\(globalIndex)")
      }
    }
  }

  // MARK: - Recent Sessions Section

  private var recentSessionsSection: some View {
    let isSearching = !searchQuery.isEmpty

    return VStack(alignment: .leading, spacing: isCompactLayout ? 2 : 4) {
      // Section Header - collapsible when not searching
      Button {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
          isRecentExpanded.toggle()
        }
      } label: {
        HStack(spacing: isCompactLayout ? 6 : 8) {
          // Chevron indicator (only when not searching)
          if !isSearching {
            Image(systemName: "chevron.right")
              .font(.system(size: isCompactLayout ? 9 : 10, weight: .semibold))
              .foregroundStyle(Color.textQuaternary)
              .rotationEffect(.degrees(isRecentExpanded ? 90 : 0))
          }

          Image(systemName: "clock")
            .font(.system(size: isCompactLayout ? 10 : 11, weight: .semibold))
            .foregroundStyle(Color.statusEnded)

          Text("RECENT")
            .font(.system(size: isCompactLayout ? 10 : 11, weight: .bold, design: .rounded))
            .foregroundStyle(Color.statusEnded)
            .tracking(0.8)

          // Count badge
          Text("\(recentSessions.count)")
            .font(.system(size: isCompactLayout ? 9 : 10, weight: .bold, design: .rounded))
            .foregroundStyle(Color.statusEnded)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.statusEnded.opacity(0.15), in: Capsule())

          Spacer()
        }
        .padding(.horizontal, isCompactLayout ? 14 : 20)
        .padding(.top, isCompactLayout ? 10 : 16)
        .padding(.bottom, isCompactLayout ? 4 : 8)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(isSearching) // Can't collapse while searching

      // Session Rows - shown when expanded OR searching
      if isRecentExpanded || isSearching {
        ForEach(Array(recentSessions.enumerated()), id: \.element.scopedID) { index, session in
          let globalIndex = sessionStartIndex + activeSessions.count + index
          switcherRow(session: session, index: globalIndex)
            .id("row-\(globalIndex)")
        }
      }
    }
  }

  // MARK: - Commands Section

  private var commandsSection: some View {
    let activeSession = targetSession ?? allVisibleSessions.first

    return VStack(alignment: .leading, spacing: isCompactLayout ? 2 : 4) {
      HStack(spacing: isCompactLayout ? 6 : 8) {
        Image(systemName: "command")
          .font(.system(size: isCompactLayout ? 10 : 11, weight: .semibold))
          .foregroundStyle(Color.accent)

        Text("COMMANDS")
          .font(.system(size: isCompactLayout ? 10 : 11, weight: .bold, design: .rounded))
          .foregroundStyle(Color.accent)
          .tracking(0.8)

        if let session = activeSession {
          Text("→")
            .font(.system(size: isCompactLayout ? 9 : 10))
            .foregroundStyle(Color.textQuaternary)

          Text(session.displayName)
            .font(.system(size: isCompactLayout ? 10 : 11, weight: .medium))
            .foregroundStyle(Color.textSecondary)
            .lineLimit(1)
        }
      }
      .padding(.horizontal, isCompactLayout ? 14 : 20)
      .padding(.top, isCompactLayout ? 6 : 8)
      .padding(.bottom, isCompactLayout ? 2 : 4)

      ForEach(Array(filteredCommands.enumerated()), id: \.element.id) { index, command in
        commandRow(command: command, index: index)
          .id("row-\(index)")
      }

      // Divider after commands
      Rectangle()
        .fill(Color.panelBorder)
        .frame(height: 1)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }
  }

  /// Dashboard row
  private var dashboardRow: some View {
    let iconSize: CGFloat = isCompactLayout ? 28 : 32

    return Button {
      router.goToDashboard()
      router.closeQuickSwitcher()
    } label: {
      HStack(spacing: isCompactLayout ? 10 : 14) {
        ZStack {
          RoundedRectangle(cornerRadius: isCompactLayout ? 7 : 8, style: .continuous)
            .fill(Color.accent.opacity(0.15))
            .frame(width: iconSize, height: iconSize)

          Image(systemName: "square.grid.2x2")
            .font(.system(size: isCompactLayout ? 13 : 14, weight: .semibold))
            .foregroundStyle(Color.accent)
        }

        VStack(alignment: .leading, spacing: 2) {
          Text("Dashboard")
            .font(.system(size: isCompactLayout ? 15 : 14, weight: .semibold))
            .foregroundStyle(.primary)

          Text("View all agents overview")
            .font(.system(size: isCompactLayout ? 12 : 11))
            .foregroundStyle(Color.textTertiary)
        }

        Spacer()

        if !isCompactLayout {
          Text("⌘0")
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
      }
      .padding(.horizontal, isCompactLayout ? 12 : 16)
      .padding(.vertical, isCompactLayout ? 10 : 10)
      .background(
        QuickSwitcherRowBackground(
          isSelected: selectedIndex == dashboardIndex,
          isHovered: hoveredIndex == dashboardIndex
        )
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovered in
      guard !isCompactLayout else { return }
      hoveredIndex = isHovered ? dashboardIndex : nil
    }
    .padding(.horizontal, isCompactLayout ? 4 : 8)
  }

  // MARK: - Switcher Row

  private func switcherRow(session: Session, index: Int) -> some View {
    let isHighlighted = selectedIndex == index || hoveredIndex == index
    let displayStatus = SessionDisplayStatus.from(session)

    return Button {
      router.navigateToSession(scopedID: session.scopedID, runtimeRegistry: runtimeRegistry)
      router.closeQuickSwitcher()
    } label: {
      HStack(spacing: isCompactLayout ? 10 : 14) {
        // Status indicator - smaller on compact, no glow
        SessionStatusDot(status: displayStatus, size: isCompactLayout ? 8 : 10, showGlow: !isCompactLayout)
          .frame(width: isCompactLayout ? 16 : 20, height: isCompactLayout ? 16 : 20)

        // Content - stacked layout for better hierarchy
        VStack(alignment: .leading, spacing: isCompactLayout ? 2 : 4) {
          // Project name + branch (top line, smaller)
          HStack(spacing: isCompactLayout ? 6 : 8) {
            Text(projectName(for: session))
              .font(.system(size: isCompactLayout ? 10 : 11, weight: .medium))
              .foregroundStyle(Color.textSecondary)
              .lineLimit(1)

            if !isCompactLayout, session.endpointName != nil {
              EndpointBadge(
                endpointName: session.endpointName,
                isDefault: session.endpointId == runtimeRegistry.activeEndpointId
              )
            }

            if let branch = session.branch {
              HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.branch")
                  .font(.system(size: isCompactLayout ? 8 : 9))
                Text(branch)
                  .font(.system(size: isCompactLayout ? 9 : 10, design: .monospaced))
                  .lineLimit(1)
              }
              .foregroundStyle(Color.gitBranch.opacity(0.7))
            }

            if !isCompactLayout, sessionObservable(for: session).forkedFrom != nil {
              ForkBadge()
            }
          }

          // Agent name (main line, prominent)
          HStack(spacing: isCompactLayout ? 8 : 10) {
            Text(agentName(for: session))
              .font(.system(size: isCompactLayout ? 15 : 14, weight: .semibold))
              .foregroundStyle(.primary)
              .lineLimit(1)

            // Activity indicator for active sessions
            if session.isActive {
              activityIndicator(for: session, status: displayStatus)
            } else {
              // Ended badge with relative time
              HStack(spacing: 4) {
                if let endedAt = session.endedAt {
                  Text(endedAt, style: .relative)
                    .font(.system(size: isCompactLayout ? 11 : 10))
                }
              }
              .foregroundStyle(Color.statusEnded)
            }
          }
        }

        Spacer(minLength: 4)

        // On compact: always show model badge, use context menu for actions
        // On desktop: show action buttons on hover/selection
        if isCompactLayout {
          UnifiedModelBadge(model: session.model, provider: session.provider, size: .mini)
        } else if isHighlighted {
          HStack(spacing: 4) {
            actionButton(icon: "terminal", tooltip: "Focus Terminal") {
              focusTerminal(for: session)
              router.closeQuickSwitcher()
            }
            actionButton(icon: "folder", tooltip: "Open in Finder") {
              _ = Platform.services.revealInFileBrowser(session.projectPath)
              router.closeQuickSwitcher()
            }
            actionButton(icon: "pencil", tooltip: "Rename") {
              renameText = session.customName ?? ""
              renamingSession = session
            }
            actionButton(icon: "doc.on.doc", tooltip: "Copy Resume") {
              let command = "claude --resume \(session.id)"
              Platform.services.copyToClipboard(command)
              router.closeQuickSwitcher()
            }
            if session.isActive {
              actionButton(icon: "xmark.circle", tooltip: "Close Session") {
                appState(for: session).endSession(session.id)
                router.closeQuickSwitcher()
              }
            }
          }
          .transition(.opacity.combined(with: .scale(scale: 0.9)))
        } else {
          UnifiedModelBadge(model: session.model, provider: session.provider, size: .mini)
        }
      }
      .padding(.horizontal, isCompactLayout ? 12 : 16)
      .padding(.vertical, isCompactLayout ? 10 : 12)
      .background(
        QuickSwitcherRowBackground(
          isSelected: selectedIndex == index,
          isHovered: hoveredIndex == index
        )
      )
      .padding(.horizontal, isCompactLayout ? 4 : 8)
      .contentShape(Rectangle())
      .animation(.easeOut(duration: 0.15), value: isHighlighted)
    }
    .buttonStyle(.plain)
    .onHover { isHovered in
      guard !isCompactLayout else { return }
      hoveredIndex = isHovered ? index : nil
    }
    .modifier(CompactContextMenuModifier(isCompact: isCompactLayout) {
      Button {
        focusTerminal(for: session)
        router.closeQuickSwitcher()
      } label: {
        Label("Focus Terminal", systemImage: "terminal")
      }

      Button {
        _ = Platform.services.revealInFileBrowser(session.projectPath)
        router.closeQuickSwitcher()
      } label: {
        Label("Open in Files", systemImage: "folder")
      }

      Button {
        renameText = session.customName ?? ""
        renamingSession = session
      } label: {
        Label("Rename", systemImage: "pencil")
      }

      Button {
        let command = "claude --resume \(session.id)"
        Platform.services.copyToClipboard(command)
        router.closeQuickSwitcher()
      } label: {
        Label("Copy Resume Command", systemImage: "doc.on.doc")
      }

      if session.isActive {
        Divider()
        Button(role: .destructive) {
          appState(for: session).endSession(session.id)
          router.closeQuickSwitcher()
        } label: {
          Label("Close Session", systemImage: "xmark.circle")
        }
      }
    })
  }

  private func actionButton(icon: String, tooltip: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: icon)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(width: 28, height: 28)
        .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    .buttonStyle(.plain)
    .help(tooltip)
  }

  // MARK: - Empty State

  private var emptyState: some View {
    let circleSize: CGFloat = isCompactLayout ? 44 : 56
    let iconSize: CGFloat = isCompactLayout ? 20 : 24

    return VStack(spacing: isCompactLayout ? 12 : 16) {
      ZStack {
        Circle()
          .fill(Color.backgroundTertiary)
          .frame(width: circleSize, height: circleSize)

        Image(systemName: "magnifyingglass")
          .font(.system(size: iconSize, weight: .medium))
          .foregroundStyle(Color.textQuaternary)
      }

      VStack(spacing: 4) {
        Text("No agents found")
          .font(.system(size: isCompactLayout ? 15 : 14, weight: .medium))
          .foregroundStyle(Color.textSecondary)

        if !searchText.isEmpty {
          Text("Try a different search term")
            .font(.system(size: isCompactLayout ? 13 : 12))
            .foregroundStyle(Color.textTertiary)
        }
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, isCompactLayout ? 36 : 48)
  }

  // MARK: - Footer

  private var footerHint: some View {
    HStack(spacing: 0) {
      hintItem(keys: "↑↓", label: "Navigate")
      footerDivider

      if quickLaunchMode != nil {
        hintItem(keys: "↵", label: "Launch")
        footerDivider
        hintItem(keys: "⇧↵", label: "Full Sheet")
      } else {
        hintItem(keys: "↵", label: "Select")
        footerDivider
        hintItem(keys: "⌘R", label: "Rename")
      }

      footerDivider
      hintItem(keys: "esc", label: "Close")

      Spacer()
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
    .background(Color.backgroundTertiary.opacity(0.3))
  }

  private var footerDivider: some View {
    Rectangle()
      .fill(Color.panelBorder)
      .frame(width: 1, height: 14)
      .padding(.horizontal, 12)
  }

  private func hintItem(keys: String, label: String) -> some View {
    HStack(spacing: 6) {
      Text(keys)
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: 4, style: .continuous))

      Text(label)
        .font(.system(size: 11))
        .foregroundStyle(Color.textTertiary)
    }
  }

  // MARK: - Helpers

  private func moveSelection(by delta: Int) {
    guard totalItems > 0 else { return }

    let newIndex = selectedIndex + delta
    if newIndex < 0 {
      selectedIndex = totalItems - 1
    } else if newIndex >= totalItems {
      selectedIndex = 0
    } else {
      selectedIndex = newIndex
    }
  }

  private func selectCurrent() {
    // Quick launch mode: launch session with selected project
    if quickLaunchMode != nil {
      guard selectedIndex >= 0, selectedIndex < recentProjects.count else { return }
      let project = recentProjects[selectedIndex]
      quickLaunchSession(path: project.path)
      return
    }

    // Commands come first
    if selectedIndex < commandCount {
      let command = filteredCommands[selectedIndex]
      executeCommand(command)
      return
    }

    // Dashboard is after commands
    if selectedIndex == dashboardIndex {
      router.goToDashboard()
      router.closeQuickSwitcher()
      return
    }

    // Sessions are after dashboard
    let sessionIndex = selectedIndex - sessionStartIndex
    guard sessionIndex >= 0, sessionIndex < allVisibleSessions.count else { return }
    let session = allVisibleSessions[sessionIndex]
    router.navigateToSession(scopedID: session.scopedID, runtimeRegistry: runtimeRegistry)
    router.closeQuickSwitcher()
  }

  private func renameCurrentSelection() {
    // Can only rename sessions (not commands or dashboard)
    guard selectedIndex >= sessionStartIndex else { return }
    let sessionIndex = selectedIndex - sessionStartIndex
    guard sessionIndex < allVisibleSessions.count else { return }
    let session = allVisibleSessions[sessionIndex]
    renameText = session.customName ?? ""
    renamingSession = session
  }

  private func focusTerminal(for session: Session) {
    Task { await TerminalService.shared.focusSession(session) }
  }

  private func focusSearchField() {
    Task { @MainActor in
      // Defer focus by one cycle so it wins against the Cmd+K invocation lifecycle.
      await Task.yield()
      isSearchFocused = true
    }
  }

  private func projectName(for session: Session) -> String {
    session.projectName ?? session.projectPath.components(separatedBy: "/").last ?? "Unknown"
  }

  private func appState(for session: Session) -> ServerAppState {
    runtimeRegistry.appState(for: session, fallback: serverState)
  }

  private func sessionObservable(for session: Session) -> SessionObservable {
    runtimeRegistry.sessionObservable(for: session, fallback: serverState)
  }

  private func agentName(for session: Session) -> String {
    // Use displayName which already strips HTML tags
    session.displayName
  }

  @ViewBuilder
  private func activityIndicator(for session: Session, status: SessionDisplayStatus) -> some View {
    let color = status.color

    HStack(spacing: 4) {
      Image(systemName: activityIcon(for: session, status: status))
        .font(.system(size: 9, weight: .medium))
      Text(activityText(for: session, status: status))
        .font(.system(size: 10, weight: .medium))
    }
    .foregroundStyle(color)
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(color.opacity(0.12), in: Capsule())
  }

  private func activityText(for session: Session, status: SessionDisplayStatus) -> String {
    switch status {
      case .permission:
        if let tool = session.pendingToolName {
          return tool
        }
        return "Permission"
      case .question:
        return "Question"
      case .working:
        if let tool = session.lastTool {
          return tool
        }
        return "Working"
      case .reply:
        return "Ready"
      case .ended:
        return "Ended"
    }
  }

  private func activityIcon(for session: Session, status: SessionDisplayStatus) -> String {
    switch status {
      case .permission:
        return "lock.fill"
      case .question:
        return "questionmark.bubble"
      case .working:
        if let tool = session.lastTool {
          return ToolCardStyle.icon(for: tool)
        }
        return "bolt.fill"
      case .reply:
        return "checkmark.circle"
      case .ended:
        return "moon.fill"
    }
  }

  // MARK: - Quick Launch

  private func loadRecentProjects() {
    guard let connection = runtimeRegistry.controlPlaneConnection else {
      recentProjects = []
      isLoadingProjects = false
      return
    }

    isLoadingProjects = true
    let endpointId = connection.endpointId
    let requestId = UUID()
    recentProjectsRequestId = requestId

    Task { @MainActor in
      defer {
        if recentProjectsRequestId == requestId, currentControlPlaneEndpointID() == endpointId {
          isLoadingProjects = false
        }
      }

      do {
        let projects = try await connection.listRecentProjects()
        guard recentProjectsRequestId == requestId, currentControlPlaneEndpointID() == endpointId else { return }
        recentProjects = projects
      } catch {
        guard recentProjectsRequestId == requestId, currentControlPlaneEndpointID() == endpointId else { return }
        recentProjects = []
      }
    }
  }

  private func currentControlPlaneEndpointID() -> UUID? {
    runtimeRegistry.primaryEndpointId ?? runtimeRegistry.activeEndpointId
  }

  private func quickLaunchSession(path: String) {
    guard let provider = quickLaunchMode else { return }
    switch provider {
      case .claude:
        onQuickLaunchClaude?(path)
      case .codex:
        onQuickLaunchCodex?(path)
    }
    router.closeQuickSwitcher()
  }

  private func openFullSheet() {
    guard let provider = quickLaunchMode else { return }
    switch provider {
      case .claude:
        router.showNewClaudeSheet = true
      case .codex:
        router.showNewCodexSheet = true
    }
    router.closeQuickSwitcher()
  }
}

// MARK: - Preview

#Preview {
  ZStack {
    Color.black.opacity(0.5)
      .ignoresSafeArea()

    QuickSwitcher(
      sessions: [
        Session(
          id: "1",
          projectPath: "/Users/developer/Developer/vizzly-cli",
          projectName: "vizzly-cli",
          branch: "feat/auth",
          model: "claude-opus-4-5-20251101",
          contextLabel: "Auth refactor",
          transcriptPath: nil,
          status: .active,
          workStatus: .working,
          startedAt: Date(),
          endedAt: nil,
          endReason: nil,
          totalTokens: 0,
          totalCostUSD: 0,
          lastActivityAt: nil,
          lastTool: nil,
          lastToolAt: nil,
          promptCount: 0,
          toolCount: 0,
          terminalSessionId: nil,
          terminalApp: nil
        ),
        Session(
          id: "2",
          projectPath: "/Users/developer/Developer/backchannel",
          projectName: "backchannel",
          branch: "main",
          model: "claude-sonnet-4-20250514",
          contextLabel: "API review",
          transcriptPath: nil,
          status: .active,
          workStatus: .waiting,
          startedAt: Date(),
          endedAt: nil,
          endReason: nil,
          totalTokens: 0,
          totalCostUSD: 0,
          lastActivityAt: nil,
          lastTool: nil,
          lastToolAt: nil,
          promptCount: 0,
          toolCount: 0,
          terminalSessionId: nil,
          terminalApp: nil
        ),
        Session(
          id: "3",
          projectPath: "/Users/developer/Developer/docs",
          projectName: "docs",
          branch: "main",
          model: "claude-haiku-3-5-20241022",
          contextLabel: nil,
          transcriptPath: nil,
          status: .ended,
          workStatus: .unknown,
          startedAt: Date().addingTimeInterval(-7_200),
          endedAt: Date().addingTimeInterval(-3_600),
          endReason: nil,
          totalTokens: 0,
          totalCostUSD: 0,
          lastActivityAt: nil,
          lastTool: nil,
          lastToolAt: nil,
          promptCount: 0,
          toolCount: 0,
          terminalSessionId: nil,
          terminalApp: nil
        ),
      ],
      onQuickLaunchClaude: nil,
      onQuickLaunchCodex: nil
    )
    .environment(AppRouter())
  }
  .frame(width: 800, height: 600)
  .environment(ServerAppState())
}

// MARK: - Compact Context Menu Modifier

/// Conditionally attaches a context menu only on compact (iOS) layouts.
/// On desktop, this is a no-op so hover-based action buttons remain primary.
struct CompactContextMenuModifier<MenuContent: View>: ViewModifier {
  let isCompact: Bool
  @ViewBuilder let menuContent: () -> MenuContent

  func body(content: Content) -> some View {
    if isCompact {
      content.contextMenu { menuContent() }
    } else {
      content
    }
  }
}

// MARK: - Row Background

struct QuickSwitcherRowBackground: View {
  let isSelected: Bool
  let isHovered: Bool

  var body: some View {
    ZStack(alignment: .leading) {
      // Background fill
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(backgroundColor)

      // Left accent border when selected
      RoundedRectangle(cornerRadius: 2, style: .continuous)
        .fill(Color.accent)
        .frame(width: 3)
        .padding(.leading, 4)
        .padding(.vertical, 6)
        .opacity(isSelected ? 1 : 0)
        .scaleEffect(x: 1, y: isSelected ? 1 : 0.5, anchor: .center)
    }
    .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isSelected)
    .animation(.easeOut(duration: 0.15), value: isHovered)
  }

  private var backgroundColor: Color {
    if isSelected {
      Color.accent.opacity(0.15)
    } else if isHovered {
      Color.surfaceHover.opacity(0.6)
    } else {
      Color.clear
    }
  }
}

// MARK: - Keyboard Navigation Modifier

struct KeyboardNavigationModifier: ViewModifier {
  let onMoveUp: () -> Void
  let onMoveDown: () -> Void
  let onMoveToFirst: () -> Void
  let onMoveToLast: () -> Void
  let onSelect: () -> Void
  let onRename: () -> Void
  let onShiftSelect: (() -> Void)?

  init(
    onMoveUp: @escaping () -> Void,
    onMoveDown: @escaping () -> Void,
    onMoveToFirst: @escaping () -> Void,
    onMoveToLast: @escaping () -> Void,
    onSelect: @escaping () -> Void,
    onRename: @escaping () -> Void,
    onShiftSelect: (() -> Void)? = nil
  ) {
    self.onMoveUp = onMoveUp
    self.onMoveDown = onMoveDown
    self.onMoveToFirst = onMoveToFirst
    self.onMoveToLast = onMoveToLast
    self.onSelect = onSelect
    self.onRename = onRename
    self.onShiftSelect = onShiftSelect
  }

  func body(content: Content) -> some View {
    content
      // Arrow keys
      .onKeyPress(keys: [.upArrow]) { _ in
        onMoveUp()
        return .handled
      }
      .onKeyPress(keys: [.downArrow]) { _ in
        onMoveDown()
        return .handled
      }
      // Enter to select (check for shift modifier first)
      .onKeyPress(keys: [.return]) { keyPress in
        if keyPress.modifiers.contains(.shift), let shiftAction = onShiftSelect {
          shiftAction()
          return .handled
        }
        onSelect()
        return .handled
      }
      // Handle all other keys for Emacs bindings and ⌘R
      .onKeyPress { keyPress in
        // Emacs: C-p (previous)
        if keyPress.key == "p", keyPress.modifiers.contains(.control) {
          onMoveUp()
          return .handled
        }
        // Emacs: C-n (next)
        if keyPress.key == "n", keyPress.modifiers.contains(.control) {
          onMoveDown()
          return .handled
        }
        // Emacs: C-a (first)
        if keyPress.key == "a", keyPress.modifiers.contains(.control) {
          onMoveToFirst()
          return .handled
        }
        // Emacs: C-e (last)
        if keyPress.key == "e", keyPress.modifiers.contains(.control) {
          onMoveDown()
          return .handled
        }
        // ⌘R to rename
        if keyPress.key == "r", keyPress.modifiers.contains(.command) {
          onRename()
          return .handled
        }
        return .ignored
      }
  }
}
