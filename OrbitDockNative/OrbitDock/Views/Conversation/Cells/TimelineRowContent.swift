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
  var endpointId: UUID?
  var clients: ServerClients?
  var fetchedContent: ServerRowContent?
  var isLoadingContent: Bool = false
  var onToggle: ((String) -> Void)?
  var isItemExpanded: ((String) -> Bool)?
  var contentForChild: ((String) -> ServerRowContent?)?
  var isChildLoading: ((String) -> Bool)?

  @Environment(\.horizontalSizeClass) private var sizeClass
  @Environment(\.rewindToMessage) private var rewindToMessage
  @Environment(\.stopTarget) private var stopTarget

  @State private var showRewindConfirmation = false

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
        userMessageView(msg: msg, isSteer: false)

      case let .steer(msg):
        userMessageView(msg: msg, isSteer: true)

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
        let isSettingsNotice = notice.title == "Session settings updated"
        let noticeIcon = isSettingsNotice
          ? "gearshape.fill"
          : (notice.severity == .error ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
        let noticeColor = isSettingsNotice
          ? Color.textSecondary
          : (notice.severity == .info ? .feedbackCaution : .statusPermission)
        SemanticInfoRowView(
          icon: noticeIcon,
          iconColor: noticeColor,
          title: notice.title,
          subtitle: nil,
          summary: notice.summary,
          detail: notice.body,
          density: isSettingsNotice ? .compact : .standard,
          emphasis: isSettingsNotice ? .subtle : .standard
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
          sessionId: sessionId, endpointId: endpointId, clients: clients,
          fetchedContent: fetchedContent,
          isLoadingContent: isLoadingContent,
          onToggle: { onToggle?(toolRow.id) }
        )

      case let .activityGroup(group):
        ActivityGroupRowView(
          group: group, isExpanded: isExpanded,
          sessionId: sessionId, endpointId: endpointId, clients: clients,
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

      case let .worker(workerRow):
        workerRowView(workerRow: workerRow)

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

  @ViewBuilder
  private func userMessageView(msg: ServerConversationMessageRow, isSteer: Bool) -> some View {
    MessageRowView(
      role: .user, content: msg.content,
      images: convertImages(msg.images),
      memoryCitation: msg.memoryCitation,
      isStreaming: msg.isStreaming,
      imageLoader: imageLoader,
      isSteer: isSteer,
      deliveryStatus: msg.deliveryStatus
    )
    .contextMenu {
      if rewindToMessage != nil {
        Button(role: .destructive) {
          showRewindConfirmation = true
        } label: {
          Label("Rewind to Here", systemImage: "arrow.uturn.backward")
        }
      }
    }
    .confirmationDialog(
      "Rewind to this message?",
      isPresented: $showRewindConfirmation,
      titleVisibility: .visible
    ) {
      Button("Rewind", role: .destructive) {
        rewindToMessage?(entry.id)
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This will undo all messages after this point.")
    }
  }

  @ViewBuilder
  private func workerRowView(workerRow: ServerConversationWorkerRow) -> some View {
    HStack(spacing: Spacing.sm) {
      WorkerRowView(
        icon: "person.2.fill",
        iconColor: .toolTask,
        title: workerRow.title,
        subtitle: workerRow.subtitle
      )

      if workerRow.worker.status == .running, stopTarget != nil {
        Button {
          stopTarget?(workerRow.worker.id)
        } label: {
          Image(systemName: "stop.fill")
            .font(.system(size: IconScale.sm))
            .foregroundStyle(Color.statusError)
        }
        .buttonStyle(.plain)
        .padding(.trailing, Spacing.sm)
      }
    }
  }
}
