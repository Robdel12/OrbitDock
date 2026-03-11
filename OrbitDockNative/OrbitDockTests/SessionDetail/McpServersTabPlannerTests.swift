import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct McpServersTabPlannerTests {
  @Test func codexApiKeySessionsShowCapabilityNotice() {
    let notice = McpServersTabPlanner.capabilityNotice(
      provider: .codex,
      codexAccountStatus: ServerCodexAccountStatus(
        authMode: .apiKey,
        requiresOpenaiAuth: false,
        account: .apiKey,
        loginInProgress: false,
        activeLoginId: nil
      )
    )

    #expect(notice?.badge == "API Key")
    #expect(notice?.style == .caution)
  }

  @Test func codexChatgptSessionsShowConnectedNotice() {
    let notice = McpServersTabPlanner.capabilityNotice(
      provider: .codex,
      codexAccountStatus: ServerCodexAccountStatus(
        authMode: .chatgpt,
        requiresOpenaiAuth: true,
        account: .chatgpt(email: "test@example.com", planType: "pro"),
        loginInProgress: false,
        activeLoginId: nil
      )
    )

    #expect(notice?.badge == "ChatGPT")
    #expect(notice?.style == .success)
  }

  @Test func codexSessionsNeedingAuthShowSignInNotice() {
    let notice = McpServersTabPlanner.capabilityNotice(
      provider: .codex,
      codexAccountStatus: ServerCodexAccountStatus(
        authMode: nil,
        requiresOpenaiAuth: true,
        account: nil,
        loginInProgress: false,
        activeLoginId: nil
      )
    )

    #expect(notice?.badge == "Not Connected")
    #expect(notice?.style == .informational)
  }

  @Test func claudeSessionsDoNotShowCodexCapabilityNotice() {
    let notice = McpServersTabPlanner.capabilityNotice(
      provider: .claude,
      codexAccountStatus: ServerCodexAccountStatus(
        authMode: .chatgpt,
        requiresOpenaiAuth: true,
        account: .chatgpt(email: nil, planType: nil),
        loginInProgress: false,
        activeLoginId: nil
      )
    )

    #expect(notice == nil)
  }
}
