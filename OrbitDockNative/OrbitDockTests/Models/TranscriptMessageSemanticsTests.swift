import Foundation
@testable import OrbitDock
import Testing

struct TranscriptMessageSemanticsTests {
  @Test func toolKindClassifiesKnownToolsAndFallbacks() {
    #expect(makeMessage(toolName: "Read").toolKind == .read)
    #expect(makeMessage(toolName: "Bash").toolKind == .bash)
    #expect(makeMessage(toolName: "handoff").toolKind == .handoff)
    #expect(makeMessage(toolName: "Hook").toolKind == .hook)
    #expect(makeMessage(toolName: "WebSearch").toolKind == .webSearch)
    #expect(makeMessage(toolName: "SomethingCustom").toolKind == .unknown)
    #expect(makeMessage(toolName: nil).toolKind == .unknown)
  }

  @Test func toolPresentationComesFromToolKind() {
    let message = makeMessage(toolName: "Edit")
    let handoffMessage = makeMessage(toolName: "handoff")
    let hookMessage = makeMessage(toolName: "Hook")

    #expect(message.toolIcon == "pencil")
    #expect(message.toolColor == "orange")
    #expect(handoffMessage.toolIcon == "arrow.triangle.branch")
    #expect(handoffMessage.toolColor == "blue")
    #expect(hookMessage.toolIcon == "bolt.badge.clock")
    #expect(hookMessage.toolColor == "teal")
  }

  @Test func bashLikeCommandUsesShellTypeAndToolKind() {
    let shellMessage = TranscriptMessage(
      id: "shell",
      type: .shell,
      content: "ls -la",
      timestamp: Date()
    )
    let bashMessage = makeMessage(toolName: "Bash")
    let readMessage = makeMessage(toolName: "Read")

    #expect(shellMessage.isBashLikeCommand)
    #expect(bashMessage.isBashLikeCommand)
    #expect(!readMessage.isBashLikeCommand)
  }

  @Test func formattedToolInputUsesKindSpecificRules() {
    let readMessage = makeMessage(toolName: "Read", toolInput: ["path": "/tmp/file.txt"])
    let taskMessage = makeMessage(toolName: "Task", toolInput: ["description": "Audit the renderer split"])
    let unknownMessage = makeMessage(toolName: "Custom", toolInput: ["value": "kept"])

    #expect(readMessage.formattedToolInput == "/tmp/file.txt")
    #expect(taskMessage.formattedToolInput == "Audit the renderer split")
    #expect(unknownMessage.formattedToolInput?.contains("\"value\"") == true)
  }

  private func makeMessage(
    toolName: String?,
    toolInput: [String: Any]? = nil
  ) -> TranscriptMessage {
    TranscriptMessage(
      id: UUID().uuidString,
      type: .tool,
      content: "",
      timestamp: Date(),
      toolName: toolName,
      toolInput: toolInput
    )
  }
}
