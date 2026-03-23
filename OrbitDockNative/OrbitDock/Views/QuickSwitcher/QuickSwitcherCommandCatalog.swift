import Foundation

enum QuickSwitcherCommandAction: Equatable {
  case goToDashboard
  case openNewSession(SessionProvider)
  case renameSession
  case openInFinder
  case copyResumeCommand
  case closeSession
}

struct QuickSwitcherCommand: Identifiable, Equatable {
  let id: String
  let name: String
  let icon: String
  let shortcut: String?
  let requiresSession: Bool
  let action: QuickSwitcherCommandAction
}

enum QuickSwitcherCommandCatalog {
  static func allCommands() -> [QuickSwitcherCommand] {
    globalCommands() + sessionCommands()
  }

  static func globalCommands() -> [QuickSwitcherCommand] {
    [
      QuickSwitcherCommand(
        id: "dashboard",
        name: "Go to Dashboard",
        icon: "square.grid.2x2",
        shortcut: "⌘0",
        requiresSession: false,
        action: .goToDashboard
      ),
      QuickSwitcherCommand(
        id: "new-claude",
        name: "New Claude Session",
        icon: "plus.circle.fill",
        shortcut: nil,
        requiresSession: false,
        action: .openNewSession(.claude)
      ),
      QuickSwitcherCommand(
        id: "new-codex",
        name: "New Codex Session",
        icon: "plus.circle.fill",
        shortcut: nil,
        requiresSession: false,
        action: .openNewSession(.codex)
      ),
    ]
  }

  static func sessionCommands() -> [QuickSwitcherCommand] {
    [
      QuickSwitcherCommand(
        id: "rename",
        name: "Rename Session",
        icon: "pencil",
        shortcut: "⌘R",
        requiresSession: true,
        action: .renameSession
      ),
      QuickSwitcherCommand(
        id: "finder",
        name: "Open in Finder",
        icon: "folder",
        shortcut: nil,
        requiresSession: true,
        action: .openInFinder
      ),
      QuickSwitcherCommand(
        id: "copy",
        name: "Copy Resume Command",
        icon: "doc.on.doc",
        shortcut: nil,
        requiresSession: true,
        action: .copyResumeCommand
      ),
      QuickSwitcherCommand(
        id: "close",
        name: "End Session",
        icon: "xmark.circle",
        shortcut: nil,
        requiresSession: true,
        action: .closeSession
      ),
    ]
  }
}
