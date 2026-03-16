import Foundation

enum QuickSwitcherCommandPlan: Equatable {
  case goToDashboard
  case openNewSession(SessionProvider)
  case renameSession(RootSessionNode)
  case openInFinder(path: String)
  case copyResumeCommand(String)
  case closeSession(RootSessionNode)
}

enum QuickSwitcherSelectionPlan: Equatable {
  case none
  case quickLaunch(path: String)
  case goToDashboard
  case openSession(RootSessionNode)
  case command(QuickSwitcherCommandPlan)
}

enum QuickSwitcherActionPlanner {
  static func capturedTargetSession(
    oldSearchText: String,
    newSearchText: String,
    selectedKind: QuickSwitcherSelectionKind,
    visibleSessions: [RootSessionNode]
  ) -> RootSessionNode? {
    if oldSearchText.isEmpty, !newSearchText.isEmpty {
      switch selectedKind {
        case let .session(index):
          guard visibleSessions.indices.contains(index) else { return visibleSessions.first }
          return visibleSessions[index]
        default:
          return visibleSessions.first
      }
    }

    if newSearchText.isEmpty {
      return nil
    }

    return nil
  }

  static func commandPlan(
    command: QuickSwitcherCommand,
    currentSession: RootSessionNode?,
    explicitTargetSession: RootSessionNode?,
    fallbackVisibleSession: RootSessionNode?
  ) -> QuickSwitcherCommandPlan? {
    let targetSession = QuickSwitcherSelectionResolver.commandTargetSession(
      currentSession: currentSession,
      explicitTargetSession: explicitTargetSession,
      fallbackVisibleSession: fallbackVisibleSession
    )

    if command.requiresSession, targetSession == nil {
      return nil
    }

    switch command.action {
      case .goToDashboard:
        return .goToDashboard
      case let .openNewSession(provider):
        return .openNewSession(provider)
      case .renameSession:
        guard let targetSession else { return nil }
        return .renameSession(targetSession)
      case .openInFinder:
        guard let targetSession else { return nil }
        return .openInFinder(path: targetSession.projectPath)
      case .copyResumeCommand:
        guard let targetSession else { return nil }
        return .copyResumeCommand("claude --resume \(targetSession.sessionId)")
      case .closeSession:
        guard let targetSession else { return nil }
        return .closeSession(targetSession)
    }
  }

  static func selectionPlan(
    selectedKind: QuickSwitcherSelectionKind,
    recentProjects: [ServerRecentProject],
    filteredCommands: [QuickSwitcherCommand],
    visibleSessions: [RootSessionNode],
    currentSession: RootSessionNode?,
    explicitTargetSession: RootSessionNode?
  ) -> QuickSwitcherSelectionPlan {
    switch selectedKind {
      case .none:
        return .none
      case let .quickLaunchProject(index):
        guard recentProjects.indices.contains(index) else { return .none }
        return .quickLaunch(path: recentProjects[index].path)
      case let .command(index):
        guard filteredCommands.indices.contains(index) else { return .none }
        guard let plan = commandPlan(
          command: filteredCommands[index],
          currentSession: currentSession,
          explicitTargetSession: explicitTargetSession,
          fallbackVisibleSession: visibleSessions.first
        ) else {
          return .none
        }
        return .command(plan)
      case .dashboard:
        return .goToDashboard
      case let .session(index):
        guard visibleSessions.indices.contains(index) else { return .none }
        return .openSession(visibleSessions[index])
    }
  }

  static func renameTargetSession(
    selectedKind: QuickSwitcherSelectionKind,
    visibleSessions: [RootSessionNode]
  ) -> RootSessionNode? {
    guard case let .session(index) = selectedKind, visibleSessions.indices.contains(index) else {
      return nil
    }

    return visibleSessions[index]
  }
}
