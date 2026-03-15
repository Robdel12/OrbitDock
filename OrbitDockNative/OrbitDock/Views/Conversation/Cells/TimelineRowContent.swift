//
//  TimelineRowContent.swift
//  OrbitDock
//
//  Single wrapper that dispatches to the correct cell view.
//  Outer horizontal margin applied HERE — cells don't add their own.
//

import SwiftUI

/// Outer horizontal inset for all timeline content.
private let timelineInset: CGFloat = Spacing.xl

struct TimelineRowContent: View {
  let entry: ServerConversationRowEntry
  let isExpanded: Bool
  var availableWidth: CGFloat = 600
  var sessionId: String = ""
  var clients: ServerClients?
  var onContentLoaded: (() -> Void)?

  /// Width available to cell content after the outer inset.
  private var innerWidth: CGFloat {
    max(100, availableWidth - timelineInset * 2)
  }

  var body: some View {
    cellContent
      .padding(.horizontal, timelineInset)
  }

  @ViewBuilder
  private var cellContent: some View {
    switch entry.row {
    case let .user(msg):
      MessageRowView(role: .user, content: msg.content, images: msg.images, isStreaming: msg.isStreaming, availableWidth: innerWidth)

    case let .assistant(msg):
      MessageRowView(role: .assistant, content: msg.content, images: msg.images, isStreaming: msg.isStreaming, availableWidth: innerWidth)

    case let .system(msg):
      MessageRowView(role: .system, content: msg.content, images: msg.images, isStreaming: msg.isStreaming, availableWidth: innerWidth)

    case let .thinking(msg):
      ThinkingRowView(content: msg.content, isStreaming: msg.isStreaming, isExpanded: isExpanded, availableWidth: innerWidth)

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
}
