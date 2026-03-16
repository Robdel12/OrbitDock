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

  @Test func formattedToolInputUsesToolDisplay() {
    let readMessage = makeMessage(
      toolName: "Read",
      toolDisplay: ServerToolDisplay.placeholder(summary: "/tmp/file.txt", toolType: "read")
    )
    let taskMessage = makeMessage(
      toolName: "Task",
      toolDisplay: ServerToolDisplay(
        summary: "Task", subtitle: "Audit the renderer split", rightMeta: nil,
        subtitleAbsorbsMeta: false, glyphSymbol: "person.2", glyphColor: "indigo",
        language: nil, diffPreview: nil, outputPreview: nil, liveOutputPreview: nil,
        todoItems: [], toolType: "task", summaryFont: "system", displayTier: "standard",
        inputDisplay: "Audit the renderer split", outputDisplay: nil, diffDisplay: nil
      )
    )

    #expect(readMessage.filePath == "/tmp/file.txt")
    #expect(taskMessage.formattedToolInput == "Audit the renderer split")
  }

  private func makeMessage(
    toolName: String?,
    toolDisplay: ServerToolDisplay? = nil
  ) -> TranscriptMessage {
    TranscriptMessage(
      id: UUID().uuidString,
      type: .tool,
      content: "",
      timestamp: Date(),
      toolName: toolName,
      toolDisplay: toolDisplay
    )
  }
}
