//
//  QuickSwitcher.swift
//  OrbitDock
//
//  Command palette for switching agents and executing actions (⌘K)
//  - No prefix: Search sessions
//  - ">" prefix: Search commands
//

import SwiftUI

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
    onCopyResume: @escaping (Session) -> Void
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
    ]
  }
}

// MARK: - Quick Switcher

struct QuickSwitcher: View {
  @Environment(DatabaseManager.self) private var database
  let sessions: [Session]
  let currentSessionId: String? // Currently selected session in ContentView
  let onSelect: (String) -> Void
  let onGoToDashboard: () -> Void
  let onClose: () -> Void

  @State private var searchText = ""
  @State private var selectedIndex = 0
  @State private var hoveredIndex: Int?
  @State private var renamingSession: Session?
  @State private var renameText = ""
  @State private var targetSession: Session? // Session that commands will act on
  @FocusState private var isSearchFocused: Bool

  /// The session currently being viewed (for commands to act on)
  private var currentSession: Session? {
    if let id = currentSessionId {
      return sessions.first { $0.id == id }
    }
    return nil
  }

  // MARK: - Search

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
          onGoToDashboard()
          onClose()
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
        onClose()
      },
      onOpenFinder: { session in
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.projectPath)
        onClose()
      },
      onCopyResume: { session in
        let command = "claude --resume \(session.id)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        onClose()
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

  /// All active sessions sorted by start time (stable order, matches dashboard)
  private var activeSessions: [Session] {
    filteredSessions
      .filter(\.isActive)
      .sorted { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
  }

  /// Recent ended sessions
  private var recentSessions: [Session] {
    filteredSessions
      .filter { !$0.isActive }
      .sorted { ($0.endedAt ?? .distantPast) > ($1.endedAt ?? .distantPast) }
      .prefix(8)
      .map { $0 }
  }

  /// Flat list for keyboard navigation (matches display order)
  private var allVisibleSessions: [Session] {
    activeSessions + recentSessions
  }

  // Total items for navigation
  // Order: Commands (if searching) → Dashboard → Sessions
  private var totalItems: Int {
    filteredCommands.count + 1 + allVisibleSessions.count // commands + dashboard + sessions
  }

  var body: some View {
    mainContent
      .onAppear {
        isSearchFocused = true
        selectedIndex = 0
      }
      .modifier(KeyboardNavigationModifier(
        onMoveUp: { moveSelection(by: -1) },
        onMoveDown: { moveSelection(by: 1) },
        onMoveToFirst: { selectedIndex = 0 },
        onMoveToLast: {
          if totalItems > 0 { selectedIndex = totalItems - 1 }
        },
        onSelect: { selectCurrent() },
        onRename: { renameCurrentSelection() }
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
      }
      .sheet(item: $renamingSession) { session in
        RenameSessionSheet(
          session: session,
          initialText: renameText,
          onSave: { newName in
            database.updateCustomName(
              sessionId: session.id,
              name: newName.isEmpty ? nil : newName
            )
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

      footerHint
    }
    .frame(width: 640)
    .background(Color.panelBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .strokeBorder(Color.panelBorder, lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.5), radius: 40, x: 0, y: 20)
  }

  private func commandRow(command: QuickCommand, index: Int) -> some View {
    Button {
      executeCommand(command)
    } label: {
      HStack(spacing: 14) {
        // Icon in colored container
        ZStack {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.accent.opacity(0.1))
            .frame(width: 32, height: 32)

          Image(systemName: command.icon)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Color.accent.opacity(0.8))
        }

        VStack(alignment: .leading, spacing: 2) {
          Text(command.name)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.primary)

          if command.requiresSession {
            Text("Applies to selected session")
              .font(.system(size: 11))
              .foregroundStyle(.tertiary)
          }
        }

        Spacer()

        if let shortcut = command.shortcut {
          Text(shortcut)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .background(
        QuickSwitcherRowBackground(
          isSelected: selectedIndex == index,
          isHovered: hoveredIndex == index
        )
      )
      .padding(.horizontal, 8)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovered in
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
    HStack(spacing: 14) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 18, weight: .medium))
        .foregroundStyle(Color.secondary)
        .frame(width: 24)

      TextField("Search sessions and commands...", text: $searchText)
        .textFieldStyle(.plain)
        .font(.system(size: 17))
        .focused($isSearchFocused)

      if !searchText.isEmpty {
        Button {
          searchText = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 16))
            .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 18)
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
        .padding(.vertical, 8)
      }
      .frame(maxHeight: 480)
      .onChange(of: selectedIndex) { _, newIndex in
        proxy.scrollTo("row-\(newIndex)", anchor: .center)
      }
    }
  }

  // MARK: - Active Sessions Section

  private var activeSessionsSection: some View {
    VStack(alignment: .leading, spacing: 4) {
      // Section Header
      HStack(spacing: 8) {
        Image(systemName: "cpu")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Color.accent)

        Text("ACTIVE")
          .font(.system(size: 11, weight: .bold, design: .rounded))
          .foregroundStyle(Color.accent)
          .tracking(0.8)

        // Count badge
        Text("\(activeSessions.count)")
          .font(.system(size: 10, weight: .bold, design: .rounded))
          .foregroundStyle(Color.accent)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(Color.accent.opacity(0.15), in: Capsule())
      }
      .padding(.horizontal, 20)
      .padding(.top, 16)
      .padding(.bottom, 8)

      // Session Rows
      ForEach(Array(activeSessions.enumerated()), id: \.element.id) { index, session in
        let globalIndex = sessionStartIndex + index
        switcherRow(session: session, index: globalIndex)
          .id("row-\(globalIndex)")
      }
    }
  }

  // MARK: - Recent Sessions Section

  private var recentSessionsSection: some View {
    VStack(alignment: .leading, spacing: 4) {
      // Section Header
      HStack(spacing: 8) {
        Image(systemName: "clock")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Color.statusEnded)

        Text("RECENT")
          .font(.system(size: 11, weight: .bold, design: .rounded))
          .foregroundStyle(Color.statusEnded)
          .tracking(0.8)

        // Count badge
        Text("\(recentSessions.count)")
          .font(.system(size: 10, weight: .bold, design: .rounded))
          .foregroundStyle(Color.statusEnded)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(Color.statusEnded.opacity(0.15), in: Capsule())
      }
      .padding(.horizontal, 20)
      .padding(.top, 16)
      .padding(.bottom, 8)

      // Session Rows
      ForEach(Array(recentSessions.enumerated()), id: \.element.id) { index, session in
        let globalIndex = sessionStartIndex + activeSessions.count + index
        switcherRow(session: session, index: globalIndex)
          .id("row-\(globalIndex)")
      }
    }
  }

  // MARK: - Commands Section

  private var commandsSection: some View {
    let activeSession = targetSession ?? allVisibleSessions.first

    return VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Image(systemName: "command")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Color.accent)

        Text("COMMANDS")
          .font(.system(size: 11, weight: .bold, design: .rounded))
          .foregroundStyle(Color.accent)
          .tracking(0.8)

        if let session = activeSession {
          Text("→")
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)

          Text(session.displayName)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      .padding(.horizontal, 20)
      .padding(.top, 8)
      .padding(.bottom, 4)

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
    Button {
      onGoToDashboard()
      onClose()
    } label: {
      HStack(spacing: 14) {
        ZStack {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.accent.opacity(0.15))
            .frame(width: 32, height: 32)

          Image(systemName: "square.grid.2x2")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.accent)
        }

        VStack(alignment: .leading, spacing: 2) {
          Text("Dashboard")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.primary)

          Text("View all agents overview")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
        }

        Spacer()

        Text("⌘0")
          .font(.system(size: 11, weight: .medium, design: .monospaced))
          .foregroundStyle(.tertiary)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
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
      hoveredIndex = isHovered ? dashboardIndex : nil
    }
    .padding(.horizontal, 8)
  }

  // MARK: - Switcher Row

  private func switcherRow(session: Session, index: Int) -> some View {
    let isHighlighted = selectedIndex == index || hoveredIndex == index
    let displayStatus = SessionDisplayStatus.from(session)

    return Button {
      onSelect(session.id)
    } label: {
      HStack(spacing: 14) {
        // Status indicator - using unified component
        SessionStatusDot(status: displayStatus, size: 10)
          .frame(width: 20, height: 20)

        // Content - stacked layout for better hierarchy
        VStack(alignment: .leading, spacing: 4) {
          // Project name + branch (top line, smaller)
          HStack(spacing: 8) {
            Text(projectName(for: session))
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(.secondary)

            if let branch = session.branch {
              HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.branch")
                  .font(.system(size: 9))
                Text(branch)
                  .font(.system(size: 10, design: .monospaced))
              }
              .foregroundStyle(Color.gitBranch.opacity(0.7))
            }
          }

          // Agent name (main line, prominent)
          HStack(spacing: 10) {
            Text(agentName(for: session))
              .font(.system(size: 14, weight: .semibold))
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
                    .font(.system(size: 10))
                }
              }
              .foregroundStyle(Color.statusEnded)
            }
          }
        }

        Spacer()

        // Action buttons (shown on hover/selection)
        if isHighlighted {
          HStack(spacing: 4) {
            // Focus terminal
            actionButton(icon: "terminal", tooltip: "Focus Terminal") {
              print("Inline button focus on session: \(session.id)")
              print("  terminalSessionId: \(session.terminalSessionId ?? "nil")")
              focusTerminal(for: session)
              onClose()
            }

            // Open in Finder
            actionButton(icon: "folder", tooltip: "Open in Finder") {
              NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.projectPath)
              onClose()
            }

            // Rename
            actionButton(icon: "pencil", tooltip: "Rename") {
              renameText = session.customName ?? ""
              renamingSession = session
            }

            // Copy resume command
            actionButton(icon: "doc.on.doc", tooltip: "Copy Resume") {
              let command = "claude --resume \(session.id)"
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(command, forType: .string)
              onClose()
            }
          }
          .transition(.opacity.combined(with: .scale(scale: 0.9)))
        } else {
          // Model badge (shown when not highlighted)
          ModelBadgeMini(model: session.model)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .background(
        QuickSwitcherRowBackground(
          isSelected: selectedIndex == index,
          isHovered: hoveredIndex == index
        )
      )
      .padding(.horizontal, 8)
      .contentShape(Rectangle())
      .animation(.easeOut(duration: 0.15), value: isHighlighted)
    }
    .buttonStyle(.plain)
    .onHover { isHovered in
      hoveredIndex = isHovered ? index : nil
    }
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
    VStack(spacing: 16) {
      ZStack {
        Circle()
          .fill(Color.backgroundTertiary)
          .frame(width: 56, height: 56)

        Image(systemName: "magnifyingglass")
          .font(.system(size: 24, weight: .medium))
          .foregroundStyle(.tertiary)
      }

      VStack(spacing: 4) {
        Text("No agents found")
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(.secondary)

        if !searchText.isEmpty {
          Text("Try a different search term")
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
        }
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 48)
  }

  // MARK: - Footer

  private var footerHint: some View {
    HStack(spacing: 0) {
      hintItem(keys: "↑↓", label: "Navigate")
      footerDivider
      hintItem(keys: "↵", label: "Select")
      footerDivider
      hintItem(keys: "⌘R", label: "Rename")
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
        .foregroundStyle(.tertiary)
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
    // Commands come first
    if selectedIndex < commandCount {
      let command = filteredCommands[selectedIndex]
      executeCommand(command)
      return
    }

    // Dashboard is after commands
    if selectedIndex == dashboardIndex {
      onGoToDashboard()
      onClose()
      return
    }

    // Sessions are after dashboard
    let sessionIndex = selectedIndex - sessionStartIndex
    guard sessionIndex >= 0, sessionIndex < allVisibleSessions.count else { return }
    let session = allVisibleSessions[sessionIndex]
    onSelect(session.id)
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
    TerminalService.shared.focusSession(session)
  }

  private func projectName(for session: Session) -> String {
    session.projectName ?? session.projectPath.components(separatedBy: "/").last ?? "Unknown"
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
      case .attention:
        if session.attentionReason == .awaitingQuestion {
          return "Question"
        }
        if let tool = session.pendingToolName {
          return tool
        }
        return "Attention"
      case .working:
        if let tool = session.lastTool {
          return tool
        }
        return "Working"
      case .ready:
        return "Ready"
      case .ended:
        return "Ended"
    }
  }

  private func activityIcon(for session: Session, status: SessionDisplayStatus) -> String {
    switch status {
      case .attention:
        if session.attentionReason == .awaitingQuestion {
          return "questionmark.bubble"
        }
        return "lock.fill"
      case .working:
        if let tool = session.lastTool {
          return toolIcon(for: tool)
        }
        return "bolt.fill"
      case .ready:
        return "checkmark.circle"
      case .ended:
        return "moon.fill"
    }
  }

  private func toolIcon(for tool: String) -> String {
    switch tool.lowercased() {
      case "read": "doc.text"
      case "edit": "pencil"
      case "write": "square.and.pencil"
      case "bash": "terminal"
      case "glob": "folder.badge.gearshape"
      case "grep": "magnifyingglass"
      case "task": "person.2"
      case "webfetch": "globe"
      case "websearch": "magnifyingglass.circle"
      case "skill": "sparkles"
      default: "gearshape"
    }
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
          projectPath: "/Users/rob/Developer/vizzly-cli",
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
          projectPath: "/Users/rob/Developer/backchannel",
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
          projectPath: "/Users/rob/Developer/docs",
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
      currentSessionId: "1",
      onSelect: { _ in },
      onGoToDashboard: {},
      onClose: {}
    )
  }
  .frame(width: 800, height: 600)
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
      // Enter to select
      .onKeyPress(keys: [.return]) { _ in
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
