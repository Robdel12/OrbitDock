//
//  TimelineRowContent.swift
//  OrbitDock
//
//  Unified SwiftUI view that dispatches to the correct cell view
//  based on the ServerConversationRow type.
//

import SwiftUI

struct TimelineRowContent: View {
  let entry: ServerConversationRowEntry
  let isExpanded: Bool
  var availableWidth: CGFloat = 600

  /// Content width after horizontal padding
  private var contentWidth: CGFloat {
    max(100, availableWidth - Spacing.lg * 2)
  }

  var body: some View {
    switch entry.row {
    case let .user(msg):
      MessageRowView(role: .user, content: msg.content, images: msg.images, isStreaming: msg.isStreaming, availableWidth: contentWidth)

    case let .assistant(msg):
      MessageRowView(role: .assistant, content: msg.content, images: msg.images, isStreaming: msg.isStreaming, availableWidth: contentWidth)

    case let .system(msg):
      MessageRowView(role: .system, content: msg.content, images: msg.images, isStreaming: msg.isStreaming, availableWidth: contentWidth)

    case let .thinking(msg):
      ThinkingRowView(content: msg.content, isStreaming: msg.isStreaming, isExpanded: isExpanded, availableWidth: contentWidth)

    case let .tool(toolRow):
      ToolCardView(toolRow: toolRow, isExpanded: isExpanded)

    case let .activityGroup(group):
      ActivityGroupRowView(group: group, isExpanded: isExpanded)

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
