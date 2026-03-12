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
  @Environment(RootShellStore.self) private var rootShellStore
  @Environment(SessionStore.self) private var serverState
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry
  @Environment(AppRouter.self) private var router

  // Quick launch callbacks
  let onQuickLaunchClaude: ((String) -> Void)?
  let onQuickLaunchCodex: ((String) -> Void)?

  @State private var quickSwitcherState = QuickSwitcherState()
  @FocusState private var isSearchFocused: Bool

  /// The session currently being viewed (for commands to act on)
  private var viewState: QuickSwitcherViewState {
    QuickSwitcherViewState.make(
      sessions: rootShellStore.records(),
      state: quickSwitcherState,
      selectedScopedID: router.selectedScopedID,
      isCompactLayout: isCompactLayout
    )
  }

  // MARK: - Search

  private var isCompactLayout: Bool {
    #if os(iOS)
      horizontalSizeClass == .compact
    #else
      false
    #endif
  }

  var body: some View {
    mainContent
      .onAppear {
        quickSwitcherState.resetSelection()
        focusSearchField()
      }
      .modifier(KeyboardNavigationModifier(
        onMoveUp: { moveSelection(by: -1) },
        onMoveDown: { moveSelection(by: 1) },
        onMoveToFirst: {
          quickSwitcherState.selectedIndex = QuickSwitcherNavigationModel.moveToFirst(
            currentIndex: quickSwitcherState.selectedIndex,
            totalItems: viewState.totalItems
          )
        },
        onMoveToLast: {
          quickSwitcherState.selectedIndex = QuickSwitcherNavigationModel.moveToLast(
            currentIndex: quickSwitcherState.selectedIndex,
            totalItems: viewState.totalItems
          )
        },
        onSelect: { selectCurrent() },
        onRename: { renameCurrentSelection() },
        onShiftSelect: viewState.isQuickLaunchMode ? { openFullSheet() } : nil
      ))
      .onChange(of: quickSwitcherState.searchText) { oldValue, newValue in
        let transition = QuickSwitcherSearchTransitionPlanner.transition(
          oldSearchText: oldValue,
          newSearchText: newValue,
          previousMode: quickSwitcherState.quickLaunchMode.map { .quickLaunch($0.intent) } ?? .standard,
          selectedKind: selectedKind,
          visibleSessions: viewState.allVisibleSessions
        )
        quickSwitcherState.applySearchTransition(transition)

        if transition.shouldLoadRecentProjects {
          loadRecentProjects()
        }
      }
      .sheet(item: $quickSwitcherState.renamingSession) { session in
        RenameSessionSheet(
          session: session,
          initialText: quickSwitcherState.renameText,
          onSave: { newName in
            let name = newName.isEmpty ? nil : newName
            Task { try? await appState(for: session).renameSession(session.sessionId, name: name) }
            quickSwitcherState.renamingSession = nil
          },
          onCancel: {
            quickSwitcherState.renamingSession = nil
          }
        )
      }
  }

  private var mainContent: some View {
    QuickSwitcherShell(
      isCompactLayout: viewState.isCompactLayout,
      isEmptyState: viewState.isEmptyState,
      searchBar: { searchBar },
      content: { resultsView },
      emptyState: { emptyState },
      footer: { footerHint }
    )
  }

  private func commandRow(command: QuickSwitcherCommand, index: Int) -> some View {
    QuickSwitcherCommandRow(
      command: command,
      isCompactLayout: viewState.isCompactLayout,
      isSelected: quickSwitcherState.selectedIndex == index,
      isHovered: quickSwitcherState.hoveredIndex == index,
      onHoverChanged: { isHovered in
        quickSwitcherState.hoveredIndex = isHovered ? index : nil
      },
      onRun: {
        runCommand(command)
      }
    )
  }

  private func runCommand(_ command: QuickSwitcherCommand) {
    guard let plan = QuickSwitcherActionPlanner.commandPlan(
      command: command,
      currentSession: viewState.currentSession,
      explicitTargetSession: viewState.targetSession,
      fallbackVisibleSession: viewState.allVisibleSessions.first
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
        quickSwitcherState.renameText = sessionObservable(for: session).customName ?? ""
        quickSwitcherState.renamingSession = session
      case .openInFinder(let path):
        _ = Platform.services.revealInFileBrowser(path)
        router.closeQuickSwitcher()
      case .copyResumeCommand(let command):
        Platform.services.copyToClipboard(command)
        router.closeQuickSwitcher()
      case .closeSession(let session):
        Task { try? await appState(for: session).endSession(session.sessionId) }
        router.closeQuickSwitcher()
    }
  }

  // MARK: - Search Bar

  private var searchBar: some View {
    QuickSwitcherSearchBar(
      isCompactLayout: viewState.isCompactLayout,
      searchText: $quickSwitcherState.searchText,
      isSearchFocused: $isSearchFocused,
      onClear: { quickSwitcherState.searchText = "" },
      onCancel: { router.closeQuickSwitcher() }
    )
  }

  // MARK: - Results View

  private var resultsView: some View {
    QuickSwitcherResultsShell(
      isCompactLayout: viewState.isCompactLayout,
      selectedIndex: quickSwitcherState.selectedIndex
    ) {
      if viewState.isQuickLaunchMode {
        quickLaunchSection
      } else {
        if !viewState.filteredCommands.isEmpty {
          commandsSection
        }

        dashboardRow
          .id("row-\(viewState.dashboardIndex)")

        if !viewState.activeSessions.isEmpty {
          activeSessionsSection
        }

        if !viewState.recentSessions.isEmpty {
          recentSessionsSection
        }
      }
    }
  }

  // MARK: - Quick Launch Section

  private var quickLaunchSection: some View {
    QuickSwitcherQuickLaunchSection(
      provider: viewState.quickLaunchMode!,
      isCompactLayout: viewState.isCompactLayout,
      isLoadingProjects: quickSwitcherState.isLoadingProjects,
      recentProjects: viewState.recentProjects,
      selectedIndex: quickSwitcherState.selectedIndex,
      hoveredIndex: quickSwitcherState.hoveredIndex,
      onOpenFullSheet: openFullSheet,
      onHoverChanged: { index, hovered in
        quickSwitcherState.hoveredIndex = hovered ? index : nil
      },
      onOpenProject: { path in
        quickLaunchSession(path: path)
      }
    )
  }

  // MARK: - Active Sessions Section

  private var activeSessionsSection: some View {
    QuickSwitcherActiveSessionsSection(
      sessions: viewState.activeSessions,
      isCompactLayout: viewState.isCompactLayout,
      sessionStartIndex: viewState.sessionStartIndex,
      row: { session, index in switcherRow(session: session, index: index) }
    )
  }

  // MARK: - Recent Sessions Section

  private var recentSessionsSection: some View {
    QuickSwitcherRecentSessionsSection(
      sessions: viewState.recentSessions,
      isCompactLayout: viewState.isCompactLayout,
      searchQuery: viewState.searchQuery,
      isExpanded: quickSwitcherState.isRecentExpanded,
      shouldShowSessions: viewState.shouldShowRecentSessions,
      sessionStartIndex: viewState.sessionStartIndex,
      activeSessionCount: viewState.activeSessions.count,
      onToggleExpanded: {
        withAnimation(Motion.standard) {
          quickSwitcherState.isRecentExpanded.toggle()
        }
      },
      row: { session, index in switcherRow(session: session, index: index) }
    )
  }

  // MARK: - Commands Section

  private var commandsSection: some View {
    let activeSession = viewState.targetSession ?? viewState.allVisibleSessions.first

    return QuickSwitcherCommandsSection(
      commands: viewState.filteredCommands,
      activeSession: activeSession,
      isCompactLayout: viewState.isCompactLayout,
      row: { command, index in commandRow(command: command, index: index) }
    )
  }

  /// Dashboard row
  private var dashboardRow: some View {
    QuickSwitcherDashboardRow(
      isCompactLayout: viewState.isCompactLayout,
      isSelected: quickSwitcherState.selectedIndex == viewState.dashboardIndex,
      isHovered: quickSwitcherState.hoveredIndex == viewState.dashboardIndex,
      onHoverChanged: { isHovered in
        quickSwitcherState.hoveredIndex = isHovered ? viewState.dashboardIndex : nil
      },
      onSelect: {
        Platform.services.playHaptic(.navigation)
        router.goToDashboard()
        router.closeQuickSwitcher()
      }
    )
  }

  // MARK: - Switcher Row

  private func switcherRow(session: RootSessionNode, index: Int) -> some View {
    QuickSwitcherSessionRow(
      session: session,
      index: index,
      isCompactLayout: viewState.isCompactLayout,
      isSelected: quickSwitcherState.selectedIndex == index,
      isHovered: quickSwitcherState.hoveredIndex == index,
      onHoverChanged: { isHovered in
        quickSwitcherState.hoveredIndex = isHovered ? index : nil
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
        performCommandPlan(.copyResumeCommand("claude --resume \(session.sessionId)"))
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
      isCompactLayout: viewState.isCompactLayout,
      searchText: quickSwitcherState.searchText
    )
  }

  // MARK: - Footer

  private var footerHint: some View {
    QuickSwitcherFooterHint(isQuickLaunchMode: viewState.isQuickLaunchMode)
  }

  // MARK: - Helpers

  private func moveSelection(by delta: Int) {
    quickSwitcherState.selectedIndex = QuickSwitcherNavigationModel.moveSelection(
      currentIndex: quickSwitcherState.selectedIndex,
      delta: delta,
      totalItems: viewState.totalItems
    )
  }

  private var selectedKind: QuickSwitcherSelectionKind {
    QuickSwitcherSelectionResolver.selectedKind(
      selectedIndex: quickSwitcherState.selectedIndex,
      isQuickLaunchMode: viewState.isQuickLaunchMode,
      quickLaunchProjectCount: viewState.recentProjects.count,
      commandCount: viewState.commandCount,
      dashboardIndex: viewState.dashboardIndex,
      sessionStartIndex: viewState.sessionStartIndex,
      visibleSessionCount: viewState.allVisibleSessions.count
    )
  }

  private func selectCurrent() {
    switch QuickSwitcherActionPlanner.selectionPlan(
      selectedKind: selectedKind,
      recentProjects: viewState.recentProjects,
      filteredCommands: viewState.filteredCommands,
      visibleSessions: viewState.allVisibleSessions,
      currentSession: viewState.currentSession,
      explicitTargetSession: viewState.targetSession
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
      visibleSessions: viewState.allVisibleSessions
    ) else {
      return
    }

    quickSwitcherState.renameText = sessionObservable(for: session).customName ?? ""
    quickSwitcherState.renamingSession = session
  }

  private func focusSearchField() {
    Task { @MainActor in
      // Defer focus by one cycle so it wins against the Cmd+K invocation lifecycle.
      await Task.yield()
      isSearchFocused = true
    }
  }

  private func appState(for session: RootSessionNode) -> SessionStore {
    runtimeRegistry.sessionStore(for: session.endpointId, fallback: serverState)
  }

  private func sessionObservable(for session: RootSessionNode) -> SessionObservable {
    appState(for: session).session(session.sessionId)
  }

  // MARK: - Quick Launch

  private func loadRecentProjects() {
    guard let clients = runtimeRegistry.primaryRuntime?.clients ?? runtimeRegistry.activeRuntime?.clients else {
      quickSwitcherState.resetRecentProjects()
      return
    }

    let endpointId = currentControlPlaneEndpointID()
    let requestId = UUID()
    quickSwitcherState.beginRecentProjectsLoad(requestId: requestId)

    Task { @MainActor in
      do {
        let projects = try await clients.filesystem.listRecentProjects()
        quickSwitcherState.finishRecentProjectsLoad(
          requestId: requestId,
          endpointId: endpointId,
          activeEndpointId: currentControlPlaneEndpointID(),
          projects: projects
        )
      } catch {
        quickSwitcherState.finishRecentProjectsLoad(
          requestId: requestId,
          endpointId: endpointId,
          activeEndpointId: currentControlPlaneEndpointID(),
          projects: []
        )
      }
    }
  }

  private func currentControlPlaneEndpointID() -> UUID? {
    runtimeRegistry.primaryEndpointId ?? runtimeRegistry.activeEndpointId
  }

  private func quickLaunchSession(path: String) {
    guard let provider = viewState.quickLaunchMode else { return }
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
    guard let provider = viewState.quickLaunchMode else { return }
    Platform.services.playHaptic(.selection)
    router.openNewSession(provider: provider == .claude ? .claude : .codex)
    router.closeQuickSwitcher()
  }
}
