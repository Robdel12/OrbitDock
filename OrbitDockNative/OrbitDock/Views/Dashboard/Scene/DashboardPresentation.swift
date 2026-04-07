import Foundation

struct DashboardPresentation {
  let groups: [ConversationProjectGroup]
  let sidebarGroups: [ConversationProjectGroup]
  let filteredConversations: [DashboardConversationRecord]
  let sidebarConversations: [DashboardConversationRecord]
}
