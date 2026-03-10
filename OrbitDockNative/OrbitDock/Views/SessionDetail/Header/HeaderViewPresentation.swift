import SwiftUI

struct HeaderViewPresentation: Equatable {
  let effortLabel: String?
  let effortColor: Color
  let showsConversationModeToggleInCompact: Bool
  let hasCompactModeControls: Bool
}

enum HeaderViewPlanner {
  static func presentation(
    effort: String?,
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
      effortLabel: HeaderCompactPresentation.effortLabel(for: effort),
      effortColor: HeaderCompactPresentation.effortColor(for: effort),
      showsConversationModeToggleInCompact: showsConversationModeToggleInCompact,
      hasCompactModeControls: hasLayoutToggle || showsConversationModeToggleInCompact
    )
  }
}
