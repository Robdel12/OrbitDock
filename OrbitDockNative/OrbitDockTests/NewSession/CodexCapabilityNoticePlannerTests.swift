import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct CodexCapabilityNoticePlannerTests {
  @Test func apiKeySessionsShowCapabilityNotice() {
    let notice = CodexCapabilityNoticePlanner.notice(
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

  @Test func chatgptSessionsShowConnectedNotice() {
    let notice = CodexCapabilityNoticePlanner.notice(
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

  @Test func sessionsNeedingAuthShowSignInNotice() {
    let notice = CodexCapabilityNoticePlanner.notice(
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

  @Test func chatgptAccountWithoutRequirementStillShowsConnectedNotice() {
    let notice = CodexCapabilityNoticePlanner.notice(
      codexAccountStatus: ServerCodexAccountStatus(
        authMode: .chatgpt,
        requiresOpenaiAuth: false,
        account: .chatgpt(email: nil, planType: nil),
        loginInProgress: false,
        activeLoginId: nil
      )
    )

    #expect(notice?.badge == "ChatGPT")
    #expect(notice?.style == .success)
  }
}
