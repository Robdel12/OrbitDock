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

  init(intent: QuickLaunchProviderIntent) {
    switch intent {
      case .claude:
        self = .claude
      case .codex:
        self = .codex
    }
  }

  var intent: QuickLaunchProviderIntent {
    switch self {
      case .claude:
        .claude
      case .codex:
        .codex
    }
  }

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

// MARK: - Quick Switcher

struct QuickSwitcher: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(SessionStore.self) private var serverState
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
    queryPlan.normalizedQuery
  }

  private var queryPlan: QuickSwitcherQueryPlan {
    QuickSwitcherQueryPlanner.plan(searchText: searchText)
  }

  // MARK: - Commands

  private var commands: [QuickSwitcherCommand] {
    QuickSwitcherCommandCatalog.allCommands()
  }

  private var filteredCommands: [QuickSwitcherCommand] {
    guard !searchQuery.isEmpty else { return [] }
    return commands.filter { $0.name.lowercased().contains(searchQuery) }
  }

  // MARK: - Sessions

  private var projection: QuickSwitcherProjection {
    QuickSwitcherProjection.make(
      sessions: sessions,
      normalizedQuery: searchQuery,
      isRecentExpanded: isRecentExpanded,
      commandCount: filteredCommands.count,
      quickLaunchProjectCount: quickLaunchMode != nil ? recentProjects.count : nil
    )
  }

  private var filteredSessions: [Session] { projection.filteredSessions }
  private var activeSessions: [Session] { projection.activeSessions }
  private var recentSessions: [Session] { projection.recentSessions }
  private var allVisibleSessions: [Session] { projection.allVisibleSessions }
  private var totalItems: Int { projection.totalItems }
  private var commandCount: Int { projection.commandCount }
  private var dashboardIndex: Int { projection.dashboardIndex }
  private var sessionStartIndex: Int { projection.sessionStartIndex }

  private var shouldShowRecentSessions: Bool {
    projection.shouldShowRecentSessions
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
        onMoveToFirst: {
          selectedIndex = QuickSwitcherNavigationModel.moveToFirst(
            currentIndex: selectedIndex,
            totalItems: totalItems
          )
        },
        onMoveToLast: {
          selectedIndex = QuickSwitcherNavigationModel.moveToLast(
            currentIndex: selectedIndex,
            totalItems: totalItems
          )
        },
        onSelect: { selectCurrent() },
        onRename: { renameCurrentSelection() },
        onShiftSelect: quickLaunchMode != nil ? { openFullSheet() } : nil
      ))
      .onChange(of: searchText) { oldValue, newValue in
        let transition = QuickSwitcherSearchTransitionPlanner.transition(
          oldSearchText: oldValue,
          newSearchText: newValue,
          previousMode: quickLaunchMode.map { .quickLaunch($0.intent) } ?? .standard,
          selectedKind: selectedKind,
          visibleSessions: allVisibleSessions
        )
        targetSession = transition.targetSession
        selectedIndex = transition.selectedIndex
        hoveredIndex = transition.hoveredIndex
        quickLaunchMode = {
          switch transition.mode {
            case .standard:
              return nil
            case .quickLaunch(let intent):
              return QuickLaunchProvider(intent: intent)
          }
        }()

        if transition.shouldLoadRecentProjects {
          loadRecentProjects()
        }
      }
      .sheet(item: $renamingSession) { session in
        RenameSessionSheet(
          session: session,
          initialText: renameText,
          onSave: { newName in
            let name = newName.isEmpty ? nil : newName
            Task { try? await appState(for: session).renameSession(session.id, name: name) }
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
    .themeShadow(Shadow.lg)
    .padding(.horizontal, isCompactLayout ? Spacing.sm_ : 0)
  }

  private func commandRow(command: QuickSwitcherCommand, index: Int) -> some View {
    QuickSwitcherCommandRow(
      command: command,
      isCompactLayout: isCompactLayout,
      isSelected: selectedIndex == index,
      isHovered: hoveredIndex == index,
      onHoverChanged: { isHovered in
        hoveredIndex = isHovered ? index : nil
      },
      onRun: {
        runCommand(command)
      }
    )
  }

  private func runCommand(_ command: QuickSwitcherCommand) {
    guard let plan = QuickSwitcherActionPlanner.commandPlan(
      command: command,
      currentSession: currentSession,
      explicitTargetSession: targetSession,
      fallbackVisibleSession: allVisibleSessions.first
    ) else {
      return
    }

    Platform.services.playHaptic(.action)
    performCommandPlan(plan)
  }

  private func performCommandPlan(_ plan: QuickSwitcherCommandPlan) {
    switch plan {
      case .goToDashboard:
        router.goToDashboard()
        router.closeQuickSwitcher()
      case .openNewSession(let provider):
        router.openNewSession(provider: provider)
        router.closeQuickSwitcher()
      case .renameSession(let session):
        renameText = session.customName ?? ""
        renamingSession = session
      case .openInFinder(let path):
        _ = Platform.services.revealInFileBrowser(path)
        router.closeQuickSwitcher()
      case .copyResumeCommand(let command):
        Platform.services.copyToClipboard(command)
        router.closeQuickSwitcher()
      case .closeSession(let session):
        Task { try? await appState(for: session).endSession(session.id) }
        router.closeQuickSwitcher()
    }
  }

  // MARK: - Search Bar

  private var searchBar: some View {
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
        Button {
          searchText = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: isCompactLayout ? TypeScale.thinkingHeading1 : TypeScale.large))
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
    .padding(.horizontal, isCompactLayout ? Spacing.lg_ : Spacing.section)
    .padding(.vertical, isCompactLayout ? Spacing.md : Spacing.lg_)
    .frame(minHeight: isCompactLayout ? nil : 40)
  }

  // MARK: - Results View

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
        .padding(.vertical, isCompactLayout ? Spacing.xs : Spacing.sm)
      }
      .frame(maxHeight: isCompactLayout ? 560 : 620)
      .onChange(of: selectedIndex) { _, newIndex in
        proxy.scrollTo("row-\(newIndex)", anchor: .center)
      }
    }
  }

  // MARK: - Quick Launch Section

  private var quickLaunchSection: some View {
    QuickSwitcherQuickLaunchSection(
      provider: quickLaunchMode!,
      isCompactLayout: isCompactLayout,
      isLoadingProjects: isLoadingProjects,
      recentProjects: recentProjects,
      selectedIndex: selectedIndex,
      hoveredIndex: hoveredIndex,
      onOpenFullSheet: openFullSheet,
      onHoverChanged: { index, hovered in
        hoveredIndex = hovered ? index : nil
      },
      onOpenProject: { path in
        quickLaunchSession(path: path)
      }
    )
  }

  // MARK: - Active Sessions Section

  private var activeSessionsSection: some View {
    VStack(alignment: .leading, spacing: isCompactLayout ? Spacing.xxs : Spacing.xs) {
      // Section Header
      HStack(spacing: isCompactLayout ? Spacing.sm_ : Spacing.sm) {
        Image(systemName: "cpu")
          .font(.system(size: isCompactLayout ? TypeScale.micro : TypeScale.meta, weight: .semibold))
          .foregroundStyle(Color.accent)

        Text("ACTIVE")
          .font(.system(size: isCompactLayout ? TypeScale.micro : TypeScale.meta, weight: .bold, design: .rounded))
          .foregroundStyle(Color.accent)
          .tracking(0.8)

        // Count badge
        Text("\(activeSessions.count)")
          .font(.system(size: isCompactLayout ? TypeScale.mini : TypeScale.micro, weight: .bold, design: .rounded))
          .foregroundStyle(Color.accent)
          .padding(.horizontal, Spacing.sm_)
          .padding(.vertical, Spacing.xxs)
          .background(Color.accent.opacity(0.15), in: Capsule())
      }
      .padding(.horizontal, isCompactLayout ? Spacing.lg_ : Spacing.section)
      .padding(.top, isCompactLayout ? Spacing.md_ : Spacing.lg)
      .padding(.bottom, isCompactLayout ? Spacing.xs : Spacing.sm)

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

    return VStack(alignment: .leading, spacing: isCompactLayout ? Spacing.xxs : Spacing.xs) {
      // Section Header - collapsible when not searching
      Button {
        withAnimation(Motion.standard) {
          isRecentExpanded.toggle()
        }
      } label: {
        HStack(spacing: isCompactLayout ? Spacing.sm_ : Spacing.sm) {
          // Chevron indicator (only when not searching)
          if !isSearching {
            Image(systemName: "chevron.right")
              .font(.system(size: isCompactLayout ? TypeScale.mini : TypeScale.micro, weight: .semibold))
              .foregroundStyle(Color.textQuaternary)
              .rotationEffect(.degrees(isRecentExpanded ? 90 : 0))
          }

          Image(systemName: "clock")
            .font(.system(size: isCompactLayout ? TypeScale.micro : TypeScale.meta, weight: .semibold))
            .foregroundStyle(Color.statusEnded)

          Text("RECENT")
            .font(.system(size: isCompactLayout ? TypeScale.micro : TypeScale.meta, weight: .bold, design: .rounded))
            .foregroundStyle(Color.statusEnded)
            .tracking(0.8)

          // Count badge
          Text("\(recentSessions.count)")
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
      .disabled(isSearching) // Can't collapse while searching

      // Session Rows - shown when expanded OR searching
      if shouldShowRecentSessions {
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

    return VStack(alignment: .leading, spacing: isCompactLayout ? Spacing.xxs : Spacing.xs) {
      HStack(spacing: isCompactLayout ? Spacing.sm_ : Spacing.sm) {
        Image(systemName: "command")
          .font(.system(size: isCompactLayout ? TypeScale.micro : TypeScale.meta, weight: .semibold))
          .foregroundStyle(Color.accent)

        Text("COMMANDS")
          .font(.system(size: isCompactLayout ? TypeScale.micro : TypeScale.meta, weight: .bold, design: .rounded))
          .foregroundStyle(Color.accent)
          .tracking(0.8)

        if let session = activeSession {
          Text("→")
            .font(.system(size: isCompactLayout ? TypeScale.mini : TypeScale.micro))
            .foregroundStyle(Color.textQuaternary)

          Text(session.displayName)
            .font(.system(size: isCompactLayout ? TypeScale.micro : TypeScale.meta, weight: .medium))
            .foregroundStyle(Color.textSecondary)
            .lineLimit(1)
        }
      }
      .padding(.horizontal, isCompactLayout ? Spacing.lg_ : Spacing.section)
      .padding(.top, isCompactLayout ? Spacing.sm_ : Spacing.sm)
      .padding(.bottom, isCompactLayout ? Spacing.xxs : Spacing.xs)

      ForEach(Array(filteredCommands.enumerated()), id: \.element.id) { index, command in
        commandRow(command: command, index: index)
          .id("row-\(index)")
      }

      // Divider after commands
      Rectangle()
        .fill(Color.panelBorder)
        .frame(height: 1)
        .padding(.horizontal, Spacing.section)
        .padding(.vertical, Spacing.sm)
    }
  }

  /// Dashboard row
  private var dashboardRow: some View {
    QuickSwitcherDashboardRow(
      isCompactLayout: isCompactLayout,
      isSelected: selectedIndex == dashboardIndex,
      isHovered: hoveredIndex == dashboardIndex,
      onHoverChanged: { isHovered in
        hoveredIndex = isHovered ? dashboardIndex : nil
      },
      onSelect: {
        Platform.services.playHaptic(.navigation)
        router.goToDashboard()
        router.closeQuickSwitcher()
      }
    )
  }

  // MARK: - Switcher Row

  private func switcherRow(session: Session, index: Int) -> some View {
    QuickSwitcherSessionRow(
      session: session,
      index: index,
      isCompactLayout: isCompactLayout,
      isSelected: selectedIndex == index,
      isHovered: hoveredIndex == index,
      onHoverChanged: { isHovered in
        hoveredIndex = isHovered ? index : nil
      },
      onNavigate: {
        Platform.services.playHaptic(.navigation)
        router.navigateToSession(scopedID: session.scopedID)
        router.closeQuickSwitcher()
      },
      onOpenInFinder: {
        performCommandPlan(.openInFinder(path: session.projectPath))
      },
      onRename: {
        performCommandPlan(.renameSession(session))
      },
      onCopyResume: {
        performCommandPlan(.copyResumeCommand("claude --resume \(session.id)"))
      },
      onClose: session.showsInMissionControl ? {
        performCommandPlan(.closeSession(session))
      } : nil,
      sessionObservable: sessionObservable(for: session)
    )
  }
  // MARK: - Empty State

  private var emptyState: some View {
    QuickSwitcherEmptyState(
      isCompactLayout: isCompactLayout,
      searchText: searchText
    )
  }

  // MARK: - Footer

  private var footerHint: some View {
    QuickSwitcherFooterHint(isQuickLaunchMode: quickLaunchMode != nil)
  }

  // MARK: - Helpers

  private func moveSelection(by delta: Int) {
    selectedIndex = QuickSwitcherNavigationModel.moveSelection(
      currentIndex: selectedIndex,
      delta: delta,
      totalItems: totalItems
    )
  }

  private var selectedKind: QuickSwitcherSelectionKind {
    QuickSwitcherSelectionResolver.selectedKind(
      selectedIndex: selectedIndex,
      isQuickLaunchMode: quickLaunchMode != nil,
      quickLaunchProjectCount: recentProjects.count,
      commandCount: commandCount,
      dashboardIndex: dashboardIndex,
      sessionStartIndex: sessionStartIndex,
      visibleSessionCount: allVisibleSessions.count
    )
  }

  private func selectCurrent() {
    switch QuickSwitcherActionPlanner.selectionPlan(
      selectedKind: selectedKind,
      recentProjects: recentProjects,
      filteredCommands: filteredCommands,
      visibleSessions: allVisibleSessions,
      currentSession: currentSession,
      explicitTargetSession: targetSession
    ) {
      case .none:
        return
      case .quickLaunch(let path):
        quickLaunchSession(path: path)
      case .command(let plan):
        Platform.services.playHaptic(.action)
        performCommandPlan(plan)
      case .goToDashboard:
        Platform.services.playHaptic(.navigation)
        router.goToDashboard()
        router.closeQuickSwitcher()
      case .openSession(let session):
        Platform.services.playHaptic(.navigation)
        router.navigateToSession(scopedID: session.scopedID)
        router.closeQuickSwitcher()
    }
  }

  private func renameCurrentSelection() {
    guard let session = QuickSwitcherActionPlanner.renameTargetSession(
      selectedKind: selectedKind,
      visibleSessions: allVisibleSessions
    ) else {
      return
    }

    renameText = session.customName ?? ""
    renamingSession = session
  }

  private func focusSearchField() {
    Task { @MainActor in
      // Defer focus by one cycle so it wins against the Cmd+K invocation lifecycle.
      await Task.yield()
      isSearchFocused = true
    }
  }

  private func appState(for session: Session) -> SessionStore {
    runtimeRegistry.sessionStore(for: session, fallback: serverState)
  }

  private func sessionObservable(for session: Session) -> SessionObservable {
    runtimeRegistry.sessionObservable(for: session, fallback: serverState)
  }

  // MARK: - Quick Launch

  private func loadRecentProjects() {
    guard let clients = runtimeRegistry.primaryRuntime?.clients ?? runtimeRegistry.activeRuntime?.clients else {
      recentProjects = []
      isLoadingProjects = false
      return
    }

    isLoadingProjects = true
    let endpointId = currentControlPlaneEndpointID()
    let requestId = UUID()
    recentProjectsRequestId = requestId

    Task { @MainActor in
      defer {
        if recentProjectsRequestId == requestId, currentControlPlaneEndpointID() == endpointId {
          isLoadingProjects = false
        }
      }

      do {
        let projects = try await clients.filesystem.listRecentProjects()
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
    Platform.services.playHaptic(.action)
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
    Platform.services.playHaptic(.selection)
    router.openNewSession(provider: provider == .claude ? .claude : .codex)
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
  .environment(SessionStore())
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
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .fill(backgroundColor)

      // Left accent border when selected
      RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
        .fill(Color.accent)
        .frame(width: 3)
        .padding(.leading, Spacing.xs)
        .padding(.vertical, Spacing.sm_)
        .opacity(isSelected ? 1 : 0)
        .scaleEffect(x: 1, y: isSelected ? 1 : 0.5, anchor: .center)
    }
    .animation(Motion.standard, value: isSelected)
    .animation(Motion.hover, value: isHovered)
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
