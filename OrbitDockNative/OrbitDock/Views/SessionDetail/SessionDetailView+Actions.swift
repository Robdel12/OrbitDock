import SwiftUI

extension SessionDetailView {
  func openPendingApprovalPanel() {
    let nextState = SessionDetailConversationChromePlanner.openPendingApprovalPanel(
      current: conversationChromeState
    )
    applyConversationChromeState(nextState, animatePendingApprovalPanel: true)
  }

  func jumpConversationToLatest() {
    applyConversationChromeState(
      SessionDetailConversationChromePlanner.jumpToLatest(current: conversationChromeState)
    )
  }

  func toggleConversationPinnedState() {
    applyConversationChromeState(
      SessionDetailConversationChromePlanner.togglePinned(current: conversationChromeState)
    )
  }
}
