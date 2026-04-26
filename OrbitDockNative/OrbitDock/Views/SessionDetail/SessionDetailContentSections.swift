import SwiftUI

struct SessionDetailConversationSection: View {
  let sessionId: String
  let session: ServerSessionContext
  let viewModel: ConversationViewModel
  let endpointId: UUID
  let isSessionActive: Bool
  let displayStatus: SessionDisplayStatus
  let currentTool: String?
  let showsOrbitStatusIndicator: Bool
  let chatViewMode: ChatViewMode
  let openFileInReview: ((String) -> Void)?
  let focusWorkerInDeck: ((String) -> Void)?
  let rewindToMessage: ((String) -> Void)?
  let stopTarget: ((String) -> Void)?
  @Binding var scrollCommand: ConversationScrollCommand?
  let onJumpToLatest: () -> Void
  let onFollowStateChanged: (ConversationFollowState) -> Void

  private var routeIdentity: String {
    "\(endpointId.uuidString):\(sessionId)"
  }

  var body: some View {
    ConversationView(
      sessionId: sessionId,
      session: session,
      viewModel: viewModel,
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
    // Keep the conversation surface firmly route-scoped. This view owns
    // subscription and bootstrap lifecycle, so a new session route should get
    // a fresh SwiftUI subtree rather than relying on soft state reuse.
    .id(routeIdentity)
    .environment(\.openFileInReview, openFileInReview)
    .environment(\.focusWorkerInDeck, focusWorkerInDeck)
    .environment(\.rewindToMessage, rewindToMessage)
    .environment(\.stopTarget, stopTarget)
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
  let session: ServerSessionContext
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
      session: session,
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
