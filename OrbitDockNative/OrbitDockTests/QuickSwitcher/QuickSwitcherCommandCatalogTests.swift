@testable import OrbitDock
import Testing

struct QuickSwitcherCommandCatalogTests {
  @Test func commandCatalogIncludesGlobalAndSessionCommandsInStableOrder() {
    let commands = QuickSwitcherCommandCatalog.allCommands()

    #expect(commands.map(\.id) == ["dashboard", "new-claude", "new-codex", "rename", "finder", "copy", "close"])
  }

  @Test func sessionCommandsRequireASessionButGlobalCommandsDoNot() {
    let globals = QuickSwitcherCommandCatalog.globalCommands()
    let sessionCommands = QuickSwitcherCommandCatalog.sessionCommands()

    for command in globals {
      #expect(command.requiresSession == false)
    }

    for command in sessionCommands {
      #expect(command.requiresSession)
    }
  }
}
