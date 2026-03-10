import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct RichMessageRenderPlanningTests {
  @Test func renderStateSharesParsedBlocksAndTotalHeightForMarkdownMessages() {
    let model = NativeRichMessageRowModel(
      messageID: "msg-markdown",
      speaker: "Claude",
      content: """
      ## Title

      Some body copy with a `code` span.
      """,
      thinking: nil,
      messageType: .assistant,
      renderMode: .markdown,
      timestamp: Date(),
      hasImages: false,
      images: []
    )

    let renderState = RichMessageRenderPlanning.renderState(for: 420, model: model) { _ in 0 }

    #expect(!renderState.blocks.isEmpty)
    #expect(renderState.totalHeight > renderState.body.bodyHeight)

    guard case let .markdown(blocks, style) = renderState.body.content else {
      Issue.record("Expected markdown render content")
      return
    }

    #expect(blocks.count == renderState.blocks.count)
    #expect(style == renderState.presentation.contentStyle)
  }

  @Test func renderStateUsesAttributedTextForStreamingThinking() {
    let model = NativeRichMessageRowModel(
      messageID: "msg-thinking",
      speaker: "Claude",
      content: String(repeating: "thinking ", count: 40),
      thinking: nil,
      messageType: .thinking,
      renderMode: .streamingPlainText,
      timestamp: Date(),
      hasImages: false,
      images: []
    )

    let renderState = RichMessageRenderPlanning.renderState(for: 420, model: model) { _ in 0 }

    #expect(renderState.blocks.isEmpty)

    guard case let .attributedText(text) = renderState.body.content else {
      Issue.record("Expected attributed text render content")
      return
    }

    #expect(text.length > 0)
    guard case .thinking = renderState.body.layoutPlan else {
      Issue.record("Expected thinking layout plan")
      return
    }
  }
}
