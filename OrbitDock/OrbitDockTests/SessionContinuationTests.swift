import Foundation
@testable import OrbitDock
import Testing

struct SessionContinuationTests {
  @Test func bootstrapPromptUsesOrbitDockCliIntrospection() {
    let continuation = SessionContinuation(
      endpointId: UUID(),
      sessionId: "od-source-123",
      provider: .claude,
      displayName: "Investigate rate limits",
      projectPath: "/tmp/orbitdock",
      model: "claude-sonnet-4",
      hasGitRepository: true
    )

    let prompt = continuation.bootstrapPrompt()

    #expect(prompt.contains("Continue work from OrbitDock session od-source-123."))
    #expect(prompt.contains("orbitdock -j session get od-source-123 -m"))
    #expect(prompt.contains("Then continue the work in this session"))
  }

  @Test func supportRequiresSameEndpointAndLocalServer() {
    let sourceEndpointId = UUID()
    let otherEndpointId = UUID()
    let continuation = SessionContinuation(
      endpointId: sourceEndpointId,
      sessionId: "od-source-123",
      provider: .codex,
      displayName: "Continue API cleanup",
      projectPath: "/tmp/orbitdock",
      model: "openai/gpt-5.3-codex",
      hasGitRepository: false
    )

    #expect(continuation.isSupported(on: sourceEndpointId, isRemoteConnection: false))
    #expect(continuation.isSupported(on: otherEndpointId, isRemoteConnection: false) == false)
    #expect(continuation.isSupported(on: sourceEndpointId, isRemoteConnection: true) == false)
  }
}
