@testable import OrbitDock
import SwiftUI
import Testing

@MainActor
struct SessionDetailShortcutPlannerTests {
  @Test func ignoresShortcutsForPassiveSessions() {
    #expect(
      SessionDetailShortcutPlanner.command(
        isDirect: false,
        modifiers: .command,
        key: KeyEquivalent("d")
      ) == nil
    )
  }

  @Test func mapsCommandDToSplitToggle() {
    #expect(
      SessionDetailShortcutPlanner.command(
        isDirect: true,
        modifiers: .command,
        key: KeyEquivalent("d")
      ) == .toggleSplit
    )
  }

  @Test func mapsCommandShiftDToReviewOnly() {
    #expect(
      SessionDetailShortcutPlanner.command(
        isDirect: true,
        modifiers: [.command, .shift],
        key: KeyEquivalent("d")
      ) == .showReviewOnly
    )
  }

  @Test func derivesNextLayoutForShortcutCommands() {
    #expect(
      SessionDetailShortcutPlanner.nextLayout(
        currentLayout: .conversationOnly,
        command: .toggleSplit
      ) == .split
    )
    #expect(
      SessionDetailShortcutPlanner.nextLayout(
        currentLayout: .split,
        command: .showReviewOnly
      ) == .reviewOnly
    )
  }
}
