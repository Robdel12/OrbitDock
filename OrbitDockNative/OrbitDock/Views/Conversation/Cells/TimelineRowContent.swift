//
//  TimelineRowContent.swift
//  OrbitDock
//
//  ALL layout lives here: padding, alignment, clipping.
//  Cells render content only — zero outer layout.
//

import SwiftUI

private let userBubbleMaxWidth: CGFloat = 640

struct TimelineRowContent: View {
  let entry: ServerConversationRowEntry
  let isExpanded: Bool
  var sessionId: String = ""
  var clients: ServerClients?
  var fetchedContent: ServerRowContent?
  var isLoadingContent: Bool = false
  var onToggle: ((String) -> Void)?
  var isItemExpanded: ((String) -> Bool)?
  var contentForChild: ((String) -> ServerRowContent?)?
  var isChildLoading: ((String) -> Bool)?

  @Environment(\.horizontalSizeClass) private var sizeClass

  private var isUserRow: Bool {
    if case .user = entry.row { return true }
    if case .steer = entry.row { return true }
    return false
  }

  private var imageLoader: ImageLoader? {
    clients?.imageLoader
  }

  private var horizontalPad: CGFloat {
    sizeClass == .compact ? Spacing.md : Spacing.lg
  }

  var body: some View {
    cellContent
      .frame(maxWidth: .infinity, alignment: isUserRow ? .trailing : .leading)
      .padding(.horizontal, horizontalPad)
      .clipped()
  }

  @ViewBuilder
  private var cellContent: some View {
    switch entry.row {
      case let .user(msg):
        MessageRowView(
          role: .user, content: msg.content,
          images: convertImages(msg.images),
          memoryCitation: msg.memoryCitation,
          isStreaming: msg.isStreaming,
          imageLoader: imageLoader,
          isSteer: false,
          deliveryStatus: msg.deliveryStatus
        )

      case let .steer(msg):
        MessageRowView(
          role: .user, content: msg.content,
          images: convertImages(msg.images),
          memoryCitation: msg.memoryCitation,
          isStreaming: msg.isStreaming,
          imageLoader: imageLoader,
          isSteer: true,
          deliveryStatus: msg.deliveryStatus
        )

      case let .assistant(msg):
        MessageRowView(
          role: .assistant, content: msg.content,
          images: convertImages(msg.images),
          memoryCitation: msg.memoryCitation,
          isStreaming: msg.isStreaming,
          imageLoader: imageLoader,
          isSteer: false,
          deliveryStatus: msg.deliveryStatus
        )

      case let .system(msg):
        MessageRowView(
          role: .system, content: msg.content,
          images: convertImages(msg.images),
          memoryCitation: msg.memoryCitation,
          isStreaming: msg.isStreaming,
          imageLoader: imageLoader,
          isSteer: false,
          deliveryStatus: msg.deliveryStatus
        )

      case let .thinking(msg):
        ThinkingRowView(
          content: msg.content, isStreaming: msg.isStreaming
        )

      case let .context(context):
        SemanticInfoRowView(
          icon: "text.document",
          iconColor: .textSecondary,
          title: context.title,
          subtitle: context.subtitle,
          summary: context.summary,
          detail: context.body
        )

      case let .notice(notice):
        SemanticInfoRowView(
          icon: notice.severity == .error ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill",
          iconColor: notice.severity == .info ? .feedbackCaution : .statusPermission,
          title: notice.title,
          subtitle: nil,
          summary: notice.summary,
          detail: notice.body
        )

      case let .shellCommand(shellCommand):
        SemanticCommandRowView(row: shellCommand)

      case let .task(task):
        SemanticInfoRowView(
          icon: task.status == .failed ? "xmark.circle.fill" : "checkmark.circle.fill",
          iconColor: task.status == .failed ? .feedbackNegative : .feedbackPositive,
          title: task.title,
          subtitle: task.outputFile ?? task.taskId,
          summary: task.summary,
          detail: task.resultText
        )

      case let .tool(toolRow):
        ToolCardView(
          toolRow: toolRow, isExpanded: isExpanded,
          sessionId: sessionId, clients: clients,
          fetchedContent: fetchedContent,
          isLoadingContent: isLoadingContent,
          onToggle: { onToggle?(toolRow.id) }
        )

      case let .activityGroup(group):
        ActivityGroupRowView(
          group: group, isExpanded: isExpanded,
          sessionId: sessionId, clients: clients,
          onToggle: onToggle, isItemExpanded: isItemExpanded,
          contentForChild: contentForChild,
          isChildLoading: isChildLoading
        )

      case let .approval(approval):
        ApprovalRowView(
          title: approval.title,
          subtitle: approval.subtitle,
          summary: approval.summary,
          isQuestion: false
        )

      case let .question(question):
        ApprovalRowView(title: question.title, subtitle: question.subtitle, summary: question.summary, isQuestion: true)

      case let .worker(worker):
        WorkerRowView(icon: "person.2.fill", iconColor: .toolTask, title: worker.title, subtitle: worker.subtitle)

      case let .plan(plan):
        WorkerRowView(icon: "list.bullet.clipboard", iconColor: .toolPlan, title: plan.title, subtitle: plan.subtitle)

      case let .hook(hook):
        WorkerRowView(icon: "link", iconColor: .textTertiary, title: hook.title, subtitle: hook.subtitle)

      case let .handoff(handoff):
        WorkerRowView(
          icon: "arrow.triangle.branch",
          iconColor: .accent,
          title: handoff.title,
          subtitle: handoff.subtitle
        )
    }
  }

  private func convertImages(_ serverImages: [ServerImageInput]?) -> [MessageImage] {
    guard let serverImages, !serverImages.isEmpty else { return [] }
    return serverImages.enumerated().compactMap { index, input in
      input.toMessageImage(index: index, sessionId: sessionId)
    }
  }
}
