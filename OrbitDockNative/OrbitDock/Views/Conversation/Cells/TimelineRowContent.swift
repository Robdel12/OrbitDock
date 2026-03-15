//
//  TimelineRowContent.swift
//  OrbitDock
//
//  ALL layout lives here: padding, alignment, clipping.
//  Cells render content only — zero outer layout.
//

import SwiftUI

private let horizontalPad: CGFloat = Spacing.lg
private let userBubbleMaxWidth: CGFloat = 640

struct TimelineRowContent: View {
  let entry: ServerConversationRowEntry
  let isExpanded: Bool
  var availableWidth: CGFloat = 600
  var sessionId: String = ""
  var clients: ServerClients?
  var onContentLoaded: (() -> Void)?

  /// Width available to cell content after horizontal padding.
  private var contentWidth: CGFloat {
    max(100, availableWidth - horizontalPad * 2)
  }

  private var isUserRow: Bool {
    if case .user = entry.row { return true }
    return false
  }

  private var imageLoader: ImageLoader? {
    clients?.imageLoader
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
        isStreaming: msg.isStreaming, availableWidth: contentWidth,
        imageLoader: imageLoader
      )

    case let .assistant(msg):
      MessageRowView(
        role: .assistant, content: msg.content,
        images: convertImages(msg.images),
        isStreaming: msg.isStreaming, availableWidth: contentWidth,
        imageLoader: imageLoader
      )

    case let .system(msg):
      MessageRowView(
        role: .system, content: msg.content,
        images: convertImages(msg.images),
        isStreaming: msg.isStreaming, availableWidth: contentWidth,
        imageLoader: imageLoader
      )

    case let .thinking(msg):
      ThinkingRowView(content: msg.content, isStreaming: msg.isStreaming, isExpanded: isExpanded, availableWidth: contentWidth)

    case let .tool(toolRow):
      ToolCardView(toolRow: toolRow, isExpanded: isExpanded, sessionId: sessionId, clients: clients, onContentLoaded: onContentLoaded)

    case let .activityGroup(group):
      ActivityGroupRowView(group: group, isExpanded: isExpanded, sessionId: sessionId, clients: clients)

    case let .approval(approval):
      ApprovalRowView(title: approval.title, subtitle: approval.subtitle, summary: approval.summary, isQuestion: false)

    case let .question(question):
      ApprovalRowView(title: question.title, subtitle: question.subtitle, summary: question.summary, isQuestion: true)

    case let .worker(worker):
      WorkerRowView(icon: "person.2.fill", iconColor: .toolTask, title: worker.title, subtitle: worker.subtitle)

    case let .plan(plan):
      WorkerRowView(icon: "list.bullet.clipboard", iconColor: .toolPlan, title: plan.title, subtitle: plan.subtitle)

    case let .hook(hook):
      WorkerRowView(icon: "link", iconColor: .textTertiary, title: hook.title, subtitle: hook.subtitle)

    case let .handoff(handoff):
      WorkerRowView(icon: "arrow.triangle.branch", iconColor: .accent, title: handoff.title, subtitle: handoff.subtitle)
    }
  }

  private func convertImages(_ serverImages: [ServerImageInput]?) -> [MessageImage] {
    guard let serverImages, !serverImages.isEmpty else { return [] }
    return serverImages.enumerated().compactMap { index, input in
      input.toMessageImage(index: index, sessionId: sessionId)
    }
  }
}
