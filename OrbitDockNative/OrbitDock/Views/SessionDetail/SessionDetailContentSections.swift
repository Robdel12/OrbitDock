import SwiftUI

struct SessionDetailConversationSection: View {
  let sessionId: String
  let sessionStore: SessionStore
  let endpointId: UUID
  let isSessionActive: Bool
  let displayStatus: SessionDisplayStatus
  let currentTool: String?
  let showsOrbitStatusIndicator: Bool
  let chatViewMode: ChatViewMode
  let openFileInReview: ((String) -> Void)?
  let focusWorkerInDeck: ((String) -> Void)?
  @Binding var scrollCommand: ConversationScrollCommand?
  let onJumpToLatest: () -> Void
  let onFollowStateChanged: (ConversationFollowState) -> Void

  var body: some View {
    ConversationView(
      sessionId: sessionId,
      sessionStore: sessionStore,
      endpointId: endpointId,
      isSessionActive: isSessionActive,
      displayStatus: displayStatus,
      currentTool: currentTool,
      showsOrbitStatusIndicator: showsOrbitStatusIndicator,
      chatViewMode: chatViewMode,
      scrollCommand: $scrollCommand,
      onJumpToLatest: onJumpToLatest,
      onFollowStateChanged: onFollowStateChanged
    )
    .environment(\.openFileInReview, openFileInReview)
    .environment(\.focusWorkerInDeck, focusWorkerInDeck)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    #if os(iOS)
      .onTapGesture {
        // Tap anywhere on the conversation to dismiss the keyboard.
        // This is the most natural dismissal gesture on iOS — users
        // expect tapping outside an input to close the keyboard.
        UIApplication.shared.sendAction(
          #selector(UIResponder.resignFirstResponder),
          to: nil, from: nil, for: nil
        )
      }
    #endif
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
