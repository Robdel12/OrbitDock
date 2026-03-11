import SwiftUI

struct SessionDetailConversationSection: View {
  let sessionId: String
  let endpointId: UUID
  let isSessionActive: Bool
  let workStatus: Session.WorkStatus
  let currentTool: String?
  let pendingToolName: String?
  let pendingPermissionDetail: String?
  let provider: Provider
  let model: String?
  let chatViewMode: ChatViewMode
  let onNavigateToReviewFile: (String, Int) -> Void
  let onOpenPendingApprovalPanel: () -> Void
  let openFileInReview: ((String) -> Void)?
  let focusWorkerInDeck: ((String) -> Void)?
  @Binding var isPinned: Bool
  @Binding var unreadCount: Int
  @Binding var scrollToBottomTrigger: Int

  var body: some View {
    ConversationView(
      sessionId: sessionId,
      endpointId: endpointId,
      isSessionActive: isSessionActive,
      workStatus: workStatus,
      currentTool: currentTool,
      pendingToolName: pendingToolName,
      pendingPermissionDetail: pendingPermissionDetail,
      provider: provider,
      model: model,
      chatViewMode: chatViewMode,
      onNavigateToReviewFile: onNavigateToReviewFile,
      onOpenPendingApprovalPanel: onOpenPendingApprovalPanel,
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
