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
  @Environment(AppStore.self) private var appStore
  @Environment(\.rootSessionActions) private var rootSessionActions
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry
  @Environment(AppRouter.self) private var router

  // Quick launch callbacks
  let onQuickLaunchClaude: ((String) -> Void)?
  let onQuickLaunchCodex: ((String) -> Void)?

  @State private var quickSwitcherState = QuickSwitcherState()
  @FocusState private var isSearchFocused: Bool

  /// The session currently being viewed (for commands to act on)
  private func makeViewState() -> QuickSwitcherViewState {
    QuickSwitcherViewState.make(
      sessions: appStore.records(),
      state: quickSwitcherState,
      selectedSessionRef: router.selectedSessionRef,
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

  private var isQuickSwitcherVisible: Bool {
    router.showQuickSwitcher
  }

  var body: some View {
    let viewState = makeViewState()

    return mainContent(viewState: viewState)
      .onAppear {
        quickSwitcherState.resetSelection()
        focusSearchField()
      }
      .modifier(KeyboardNavigationModifier(
        isEnabled: isQuickSwitcherVisible,
        onMoveUp: { moveSelection(by: -1, viewState: viewState) },
        onMoveDown: { moveSelection(by: 1, viewState: viewState) },
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
        onSelect: { selectCurrent(viewState: viewState) },
        onRename: { renameCurrentSelection(viewState: viewState) },
        onShiftSelect: viewState.isQuickLaunchMode ? { openFullSheet(viewState: viewState) } : nil
      ))
      .onChange(of: quickSwitcherState.searchText) { oldValue, newValue in
        let transition = QuickSwitcherSearchTransitionPlanner.transition(
          oldSearchText: oldValue,
          newSearchText: newValue,
          previousMode: quickSwitcherState.quickLaunchMode.map { .quickLaunch($0.intent) } ?? .standard,
          selectedKind: selectedKind(viewState: viewState),
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
            Task { try? await rootSessionActions.renameSession(session, name: name) }
            quickSwitcherState.renamingSession = nil
          },
          onCancel: {
            quickSwitcherState.renamingSession = nil
          }
        )
      }
  }

  private func mainContent(viewState: QuickSwitcherViewState) -> some View {
    QuickSwitcherShell(
      isCompactLayout: viewState.isCompactLayout,
      isEmptyState: viewState.isEmptyState,
      searchBar: { searchBar(viewState: viewState) },
      content: { resultsView(viewState: viewState) },
      emptyState: { emptyState(viewState: viewState) },
      footer: { footerHint(viewState: viewState) }
    )
  }

  private func commandRow(
    command: QuickSwitcherCommand,
    index: Int,
    viewState: QuickSwitcherViewState
  ) -> some View {
    QuickSwitcherCommandRow(
      command: command,
      isCompactLayout: viewState.isCompactLayout,
      isSelected: quickSwitcherState.selectedIndex == index,
      isHovered: quickSwitcherState.hoveredIndex == index,
      onHoverChanged: { isHovered in
        quickSwitcherState.hoveredIndex = isHovered ? index : nil
      },
      onRun: {
        runCommand(command, viewState: viewState)
      }
    )
  }

  private func runCommand(_ command: QuickSwitcherCommand, viewState: QuickSwitcherViewState) {
    guard isQuickSwitcherVisible else { return }
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
    guard isQuickSwitcherVisible else { return }

    switch plan {
      case .goToDashboard:
        navigateToDashboard()
      case let .openNewSession(provider):
        router.openNewSession(provider: provider)
        closeQuickSwitcherIfVisible()
      case let .renameSession(session):
        quickSwitcherState.renameText = session.customName ?? ""
        quickSwitcherState.renamingSession = session
      case let .openInFinder(path):
        _ = Platform.services.revealInFileBrowser(path)
        closeQuickSwitcherIfVisible()
      case let .copyResumeCommand(command):
        Platform.services.copyToClipboard(command)
        closeQuickSwitcherIfVisible()
      case let .closeSession(session):
        Task { try? await rootSessionActions.endSession(session) }
        closeQuickSwitcherIfVisible()
    }
  }

  // MARK: - Search Bar

  private func searchBar(viewState: QuickSwitcherViewState) -> some View {
    QuickSwitcherSearchBar(
      isCompactLayout: viewState.isCompactLayout,
      searchText: $quickSwitcherState.searchText,
      isSearchFocused: $isSearchFocused,
      onClear: { quickSwitcherState.searchText = "" },
      onCancel: { closeQuickSwitcherIfVisible() }
    )
  }

  // MARK: - Results View

  private func resultsView(viewState: QuickSwitcherViewState) -> some View {
    QuickSwitcherResultsShell(
      isCompactLayout: viewState.isCompactLayout,
      selectedIndex: quickSwitcherState.selectedIndex
    ) {
      if viewState.isQuickLaunchMode {
        quickLaunchSection(viewState: viewState)
      } else {
        if !viewState.filteredCommands.isEmpty {
          commandsSection(viewState: viewState)
        }

        dashboardRow(viewState: viewState)
          .id("row-\(viewState.dashboardIndex)")

        if !viewState.activeSessions.isEmpty {
          activeSessionsSection(viewState: viewState)
        }

        if !viewState.recentSessions.isEmpty {
          recentSessionsSection(viewState: viewState)
        }
      }
    }
  }

  // MARK: - Quick Launch Section

  private func quickLaunchSection(viewState: QuickSwitcherViewState) -> some View {
    QuickSwitcherQuickLaunchSection(
      provider: viewState.quickLaunchMode!,
      isCompactLayout: viewState.isCompactLayout,
      isLoadingProjects: quickSwitcherState.isLoadingProjects,
      recentProjects: viewState.recentProjects,
      selectedIndex: quickSwitcherState.selectedIndex,
      hoveredIndex: quickSwitcherState.hoveredIndex,
      onOpenFullSheet: { openFullSheet(viewState: viewState) },
      onHoverChanged: { index, hovered in
        quickSwitcherState.hoveredIndex = hovered ? index : nil
      },
      onOpenProject: { path in
        quickLaunchSession(path: path, viewState: viewState)
      }
    )
  }

  // MARK: - Active Sessions Section

  private func activeSessionsSection(viewState: QuickSwitcherViewState) -> some View {
    QuickSwitcherActiveSessionsSection(
      sessions: viewState.activeSessions,
      isCompactLayout: viewState.isCompactLayout,
      sessionStartIndex: viewState.sessionStartIndex,
      row: { session, index in switcherRow(session: session, index: index, viewState: viewState) }
    )
  }

  // MARK: - Recent Sessions Section

  private func recentSessionsSection(viewState: QuickSwitcherViewState) -> some View {
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
      row: { session, index in switcherRow(session: session, index: index, viewState: viewState) }
    )
  }

  // MARK: - Commands Section

  private func commandsSection(viewState: QuickSwitcherViewState) -> some View {
    let activeSession = viewState.targetSession ?? viewState.allVisibleSessions.first

    return QuickSwitcherCommandsSection(
      commands: viewState.filteredCommands,
      activeSession: activeSession,
      isCompactLayout: viewState.isCompactLayout,
      row: { command, index in commandRow(command: command, index: index, viewState: viewState) }
    )
  }

  /// Dashboard row
  private func dashboardRow(viewState: QuickSwitcherViewState) -> some View {
    QuickSwitcherDashboardRow(
      isCompactLayout: viewState.isCompactLayout,
      isSelected: quickSwitcherState.selectedIndex == viewState.dashboardIndex,
      isHovered: quickSwitcherState.hoveredIndex == viewState.dashboardIndex,
      onHoverChanged: { isHovered in
        quickSwitcherState.hoveredIndex = isHovered ? viewState.dashboardIndex : nil
      },
      onSelect: {
        Platform.services.playHaptic(.navigation)
        navigateToDashboard()
      }
    )
  }

  // MARK: - Switcher Row

  private func switcherRow(
    session: RootSessionNode,
    index: Int,
    viewState: QuickSwitcherViewState
  ) -> some View {
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
        navigateToSession(session)
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
      } : nil
    )
  }

  // MARK: - Empty State

  private func emptyState(viewState: QuickSwitcherViewState) -> some View {
    QuickSwitcherEmptyState(
      isCompactLayout: viewState.isCompactLayout,
      searchText: quickSwitcherState.searchText
    )
  }

  // MARK: - Footer

  private func footerHint(viewState: QuickSwitcherViewState) -> some View {
    QuickSwitcherFooterHint(isQuickLaunchMode: viewState.isQuickLaunchMode)
  }

  // MARK: - Helpers

  private func moveSelection(by delta: Int, viewState: QuickSwitcherViewState) {
    quickSwitcherState.selectedIndex = QuickSwitcherNavigationModel.moveSelection(
      currentIndex: quickSwitcherState.selectedIndex,
      delta: delta,
      totalItems: viewState.totalItems
    )
  }

  private func selectedKind(viewState: QuickSwitcherViewState) -> QuickSwitcherSelectionKind {
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

  private func selectCurrent(viewState: QuickSwitcherViewState) {
    guard isQuickSwitcherVisible else { return }
    let selectedKind = selectedKind(viewState: viewState)

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
      case let .quickLaunch(path):
        quickLaunchSession(path: path, viewState: viewState)
      case let .command(plan):
        Platform.services.playHaptic(.action)
        performCommandPlan(plan)
      case .goToDashboard:
        Platform.services.playHaptic(.navigation)
        navigateToDashboard()
      case let .openSession(session):
        Platform.services.playHaptic(.navigation)
        navigateToSession(session)
    }
  }

  private func renameCurrentSelection(viewState: QuickSwitcherViewState) {
    let selectedKind = selectedKind(viewState: viewState)
    guard let session = QuickSwitcherActionPlanner.renameTargetSession(
      selectedKind: selectedKind,
      visibleSessions: viewState.allVisibleSessions
    ) else {
      return
    }

    quickSwitcherState.renameText = session.customName ?? ""
    quickSwitcherState.renamingSession = session
  }

  private func focusSearchField() {
    Task { @MainActor in
      // Defer focus by one cycle so it wins against the Cmd+K invocation lifecycle.
      await Task.yield()
      isSearchFocused = true
    }
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

  private func quickLaunchSession(path: String, viewState: QuickSwitcherViewState) {
    guard isQuickSwitcherVisible else { return }
    guard let provider = viewState.quickLaunchMode else { return }
    Platform.services.playHaptic(.action)
    switch provider {
      case .claude:
        onQuickLaunchClaude?(path)
      case .codex:
        onQuickLaunchCodex?(path)
    }
    closeQuickSwitcherIfVisible()
  }

  private func openFullSheet(viewState: QuickSwitcherViewState) {
    guard isQuickSwitcherVisible else { return }
    guard let provider = viewState.quickLaunchMode else { return }
    Platform.services.playHaptic(.selection)
    router.openNewSession(provider: provider == .claude ? .claude : .codex)
    closeQuickSwitcherIfVisible()
  }

  private func navigateToDashboard() {
    guard isQuickSwitcherVisible else { return }
    router.goToDashboard(source: .quickSwitcher)
    closeQuickSwitcherIfVisible()
  }

  private func navigateToSession(_ session: RootSessionNode) {
    guard isQuickSwitcherVisible else { return }
    router.selectSession(session.sessionRef, source: .quickSwitcher)
    closeQuickSwitcherIfVisible()
  }

  private func closeQuickSwitcherIfVisible() {
    guard isQuickSwitcherVisible else { return }
    router.closeQuickSwitcher()
  }
}
