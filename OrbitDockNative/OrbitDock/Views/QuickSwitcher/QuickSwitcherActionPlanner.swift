import Foundation

enum QuickSwitcherCommandPlan: Equatable {
  case goToDashboard
  case openNewSession(SessionProvider)
  case renameSession(RootSessionRecord)
  case openInFinder(path: String)
  case copyResumeCommand(String)
  case closeSession(RootSessionRecord)
}

enum QuickSwitcherSelectionPlan: Equatable {
  case none
  case quickLaunch(path: String)
  case goToDashboard
  case openSession(RootSessionRecord)
  case command(QuickSwitcherCommandPlan)
}

enum QuickSwitcherActionPlanner {
  static func capturedTargetSession(
    oldSearchText: String,
    newSearchText: String,
    selectedKind: QuickSwitcherSelectionKind,
    visibleSessions: [RootSessionRecord]
  ) -> RootSessionRecord? {
    if oldSearchText.isEmpty, !newSearchText.isEmpty {
      switch selectedKind {
        case .session(let index):
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

  static func capturedTargetSession(
    oldSearchText: String,
    newSearchText: String,
    selectedKind: QuickSwitcherSelectionKind,
    visibleSessions: [SessionSummary]
  ) -> RootSessionRecord? {
    capturedTargetSession(
      oldSearchText: oldSearchText,
      newSearchText: newSearchText,
      selectedKind: selectedKind,
      visibleSessions: visibleSessions.map(RootSessionRecord.init(summary:))
    )
  }

  static func commandPlan(
    command: QuickSwitcherCommand,
    currentSession: RootSessionRecord?,
    explicitTargetSession: RootSessionRecord?,
    fallbackVisibleSession: RootSessionRecord?
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
      case .openNewSession(let provider):
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

  static func commandPlan(
    command: QuickSwitcherCommand,
    currentSession: SessionSummary?,
    explicitTargetSession: SessionSummary?,
    fallbackVisibleSession: SessionSummary?
  ) -> QuickSwitcherCommandPlan? {
    commandPlan(
      command: command,
      currentSession: currentSession.map(RootSessionRecord.init(summary:)),
      explicitTargetSession: explicitTargetSession.map(RootSessionRecord.init(summary:)),
      fallbackVisibleSession: fallbackVisibleSession.map(RootSessionRecord.init(summary:))
    )
  }

  static func selectionPlan(
    selectedKind: QuickSwitcherSelectionKind,
    recentProjects: [ServerRecentProject],
    filteredCommands: [QuickSwitcherCommand],
    visibleSessions: [RootSessionRecord],
    currentSession: RootSessionRecord?,
    explicitTargetSession: RootSessionRecord?
  ) -> QuickSwitcherSelectionPlan {
    switch selectedKind {
      case .none:
        return .none
      case .quickLaunchProject(let index):
        guard recentProjects.indices.contains(index) else { return .none }
        return .quickLaunch(path: recentProjects[index].path)
      case .command(let index):
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
      case .session(let index):
        guard visibleSessions.indices.contains(index) else { return .none }
        return .openSession(visibleSessions[index])
    }
  }

  static func selectionPlan(
    selectedKind: QuickSwitcherSelectionKind,
    recentProjects: [ServerRecentProject],
    filteredCommands: [QuickSwitcherCommand],
    visibleSessions: [SessionSummary],
    currentSession: SessionSummary?,
    explicitTargetSession: SessionSummary?
  ) -> QuickSwitcherSelectionPlan {
    selectionPlan(
      selectedKind: selectedKind,
      recentProjects: recentProjects,
      filteredCommands: filteredCommands,
      visibleSessions: visibleSessions.map(RootSessionRecord.init(summary:)),
      currentSession: currentSession.map(RootSessionRecord.init(summary:)),
      explicitTargetSession: explicitTargetSession.map(RootSessionRecord.init(summary:))
    )
  }

  static func renameTargetSession(
    selectedKind: QuickSwitcherSelectionKind,
    visibleSessions: [RootSessionRecord]
  ) -> RootSessionRecord? {
    guard case .session(let index) = selectedKind, visibleSessions.indices.contains(index) else {
      return nil
    }

    return visibleSessions[index]
  }

  static func renameTargetSession(
    selectedKind: QuickSwitcherSelectionKind,
    visibleSessions: [SessionSummary]
  ) -> RootSessionRecord? {
    renameTargetSession(
      selectedKind: selectedKind,
      visibleSessions: visibleSessions.map(RootSessionRecord.init(summary:))
    )
  }

}
