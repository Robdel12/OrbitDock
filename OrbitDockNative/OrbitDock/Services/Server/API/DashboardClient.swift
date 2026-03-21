import Foundation

struct DashboardClient: Sendable {
  struct DashboardConversationsResponse: Decodable {
    let conversations: [ServerDashboardConversationItem]
  }

  let http: ServerHTTPClient

  func fetchConversations() async throws -> [ServerDashboardConversationItem] {
    let response: DashboardConversationsResponse = try await http.get("/api/dashboard/conversations")
    return response.conversations
  }
}
