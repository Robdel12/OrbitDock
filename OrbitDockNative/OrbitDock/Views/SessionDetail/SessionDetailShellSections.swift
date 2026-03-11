import SwiftUI

struct SessionDetailMainContentArea<Conversation: View, Review: View, Companion: View>: View {
  let layoutConfig: LayoutConfiguration
  @ViewBuilder let conversation: () -> Conversation
  @ViewBuilder let review: () -> Review
  @ViewBuilder let companion: () -> Companion

  var body: some View {
    HStack(spacing: 0) {
      if layoutConfig != .reviewOnly {
        conversation()
          .frame(maxWidth: .infinity)

        companion()
      }

      if layoutConfig != .conversationOnly {
        Divider()
          .foregroundStyle(Color.panelBorder)

        review()
          .frame(maxWidth: .infinity)
      }
    }
  }
}

struct SessionDetailFooter<DirectComposer: View, TakeOverBar: View, PassiveActionBar: View>: View {
  let mode: SessionDetailFooterMode
  @ViewBuilder let directComposer: () -> DirectComposer
  @ViewBuilder let takeOverBar: () -> TakeOverBar
  @ViewBuilder let passiveActionBar: () -> PassiveActionBar

  var body: some View {
    switch mode {
      case .direct:
        directComposer()
      case .passiveWithTakeOver:
        VStack(spacing: 0) {
          takeOverBar()
          passiveActionBar()
        }
      case .passiveOnly:
        passiveActionBar()
    }
  }
}
