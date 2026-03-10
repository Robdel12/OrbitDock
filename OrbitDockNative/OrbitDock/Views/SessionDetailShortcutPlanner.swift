import SwiftUI

enum SessionDetailShortcutCommand: Equatable {
  case toggleSplit
  case showReviewOnly
}

enum SessionDetailShortcutPlanner {
  static func command(
    isDirect: Bool,
    modifiers: EventModifiers,
    key: KeyEquivalent
  ) -> SessionDetailShortcutCommand? {
    guard isDirect else { return nil }

    if modifiers == .command, key == KeyEquivalent("d") {
      return .toggleSplit
    }

    if modifiers == [.command, .shift], key == KeyEquivalent("d") {
      return .showReviewOnly
    }

    return nil
  }

  static func nextLayout(
    currentLayout: LayoutConfiguration,
    command: SessionDetailShortcutCommand
  ) -> LayoutConfiguration {
    switch command {
      case .toggleSplit:
        SessionDetailLayoutPlanner.nextLayout(
          currentLayout: currentLayout,
          intent: .toggleSplitShortcut
        )
      case .showReviewOnly:
        SessionDetailLayoutPlanner.nextLayout(
          currentLayout: currentLayout,
          intent: .showReviewOnlyShortcut
        )
    }
  }
}
