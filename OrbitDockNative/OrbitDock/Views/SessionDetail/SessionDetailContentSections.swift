import SwiftUI

struct SessionDetailConversationSection: View {
  let sessionId: String
  let sessionStore: SessionStore
  let endpointId: UUID
  let isSessionActive: Bool
  let displayStatus: SessionDisplayStatus
  let currentTool: String?
  let chatViewMode: ChatViewMode
  let openFileInReview: ((String) -> Void)?
  let focusWorkerInDeck: ((String) -> Void)?
  @Binding var jumpToMessageTarget: ConversationJumpTarget?
  @Binding var isPinned: Bool
  @Binding var unreadCount: Int
  @Binding var scrollToBottomTrigger: Int

  var body: some View {
    ConversationView(
      sessionId: sessionId,
      sessionStore: sessionStore,
      endpointId: endpointId,
      isSessionActive: isSessionActive,
      displayStatus: displayStatus,
      currentTool: currentTool,
      chatViewMode: chatViewMode,
      jumpToMessageTarget: $jumpToMessageTarget,
      isPinned: $isPinned,
      unreadCount: $unreadCount,
      scrollToBottomTrigger: $scrollToBottomTrigger
    )
    .environment(\.openFileInReview, openFileInReview)
    .environment(\.focusWorkerInDeck, focusWorkerInDeck)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct SessionDetailReviewSection: View {
  let sessionId: String
  let sessionStore: SessionStore
  let projectPath: String
  let isSessionActive: Bool
  let compact: Bool
  @Binding var reviewFileId: String?
  @Binding var selectedCommentIds: Set<String>
  @Binding var navigateToComment: ServerReviewComment?
  let onDismiss: () -> Void

  var body: some View {
    ReviewCanvas(
      sessionId: sessionId,
      sessionStore: sessionStore,
      projectPath: projectPath,
      isSessionActive: isSessionActive,
      compact: compact,
      navigateToFileId: $reviewFileId,
      onDismiss: onDismiss,
      selectedCommentIds: $selectedCommentIds,
      navigateToComment: $navigateToComment
    )
  }
}
