import SwiftUI

struct HeaderViewPresentation: Equatable {
  let showsConversationModeToggleInCompact: Bool
  let hasCompactModeControls: Bool
}

enum HeaderViewPlanner {
  static func presentation(
    hasLayoutToggle: Bool,
    hasChatModeToggle: Bool,
    compactLayout: LayoutConfiguration?
  ) -> HeaderViewPresentation {
    let showsConversationModeToggleInCompact =
      if !hasChatModeToggle {
        false
      } else if compactLayout == .reviewOnly {
        false
      } else {
        true
      }

    return HeaderViewPresentation(
      showsConversationModeToggleInCompact: showsConversationModeToggleInCompact,
      hasCompactModeControls: hasLayoutToggle || showsConversationModeToggleInCompact
    )
  }
}
