import Foundation

struct DashboardPresentation {
  let groups: [ConversationProjectGroup]
  let sidebarGroups: [ConversationProjectGroup]
  let filteredConversations: [DashboardConversationRecord]
  let sidebarConversations: [DashboardConversationRecord]

  /// Pinned conversations in pin order (most recently pinned last).
  /// These are excluded from sidebarGroups to avoid duplication.
  let pinnedConversations: [DashboardConversationRecord]
}
