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
    QuickSwitcherShell(
      isCompactLayout: isCompactLayout,
      isEmptyState: allVisibleSessions.isEmpty && filteredCommands.isEmpty && !searchQuery.isEmpty,
      searchBar: { searchBar },
      content: { resultsView },
      emptyState: { emptyState },
      footer: { footerHint }
    )
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
    QuickSwitcherSearchBar(
      isCompactLayout: isCompactLayout,
      searchText: $searchText,
      isSearchFocused: $isSearchFocused,
      onClear: { searchText = "" },
      onCancel: { router.closeQuickSwitcher() }
    )
  }

  // MARK: - Results View

  private var resultsView: some View {
    QuickSwitcherResultsShell(
      isCompactLayout: isCompactLayout,
      selectedIndex: selectedIndex
    ) {
      if quickLaunchMode != nil {
        quickLaunchSection
      } else {
        if !filteredCommands.isEmpty {
          commandsSection
        }

        dashboardRow
          .id("row-\(dashboardIndex)")

        if !activeSessions.isEmpty {
          activeSessionsSection
        }

        if !recentSessions.isEmpty {
          recentSessionsSection
        }
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
    QuickSwitcherActiveSessionsSection(
      sessions: activeSessions,
      isCompactLayout: isCompactLayout,
      sessionStartIndex: sessionStartIndex,
      row: { session, index in switcherRow(session: session, index: index) }
    )
  }

  // MARK: - Recent Sessions Section

  private var recentSessionsSection: some View {
    QuickSwitcherRecentSessionsSection(
      sessions: recentSessions,
      isCompactLayout: isCompactLayout,
      searchQuery: searchQuery,
      isExpanded: isRecentExpanded,
      shouldShowSessions: shouldShowRecentSessions,
      sessionStartIndex: sessionStartIndex,
      activeSessionCount: activeSessions.count,
      onToggleExpanded: {
        withAnimation(Motion.standard) {
          isRecentExpanded.toggle()
        }
      },
      row: { session, index in switcherRow(session: session, index: index) }
    )
  }

  // MARK: - Commands Section

  private var commandsSection: some View {
    let activeSession = targetSession ?? allVisibleSessions.first

    return QuickSwitcherCommandsSection(
      commands: filteredCommands,
      activeSession: activeSession,
      isCompactLayout: isCompactLayout,
      row: { command, index in commandRow(command: command, index: index) }
    )
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
