import CoreGraphics
import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct ConversationRichMessagePresentationTests {
  @Test func userBubbleLayoutPlanMatchesSharedBubbleGeometry() {
    let image = MessageImage(
      source: .filePath("/tmp/demo.png"),
      mimeType: "image/png",
      byteCount: 1_024,
      pixelWidth: 640,
      pixelHeight: 480
    )
    let model = NativeRichMessageRowModel(
      messageID: "msg-1",
      speaker: "You",
      content: "A short user message",
      thinking: nil,
      messageType: .user,
      renderMode: .markdown,
      timestamp: Date(),
      hasImages: true,
      images: [image]
    )
    let presentation = ConversationRichMessageLayout.presentation(for: model)

    let plan = ConversationRichMessageLayout.bodyLayoutPlan(
      totalWidth: 500,
      model: model,
      presentation: presentation,
      contentHeight: 80
    )

    guard case let .userBubble(backgroundFrame, accentFrame, contentFrame, imagePlacement) = plan else {
      Issue.record("Expected user bubble layout plan")
      return
    }

    let availableWidth = min(
      500 - ConversationRichMessageLayout.laneHorizontalInset * 2,
      ConversationRichMessageLayout.userRailMaxWidth
    )
    let expectedContentWidth =
      availableWidth
      - ConversationRichMessageLayout.userBubbleHorizontalPad * 2
      - ConversationRichMessageLayout.userAccentBarWidth

    #expect(backgroundFrame.origin.x == ConversationRichMessageLayout.laneHorizontalInset)
    #expect(backgroundFrame.size.width == availableWidth)
    #expect(backgroundFrame.size.height == 100)
    #expect(accentFrame.origin.x == backgroundFrame.maxX - EdgeBar.width)
    #expect(accentFrame.size.width == EdgeBar.width)
    #expect(contentFrame.origin.x == backgroundFrame.minX + ConversationRichMessageLayout.userBubbleHorizontalPad)
    #expect(contentFrame.origin.y == ConversationRichMessageLayout.userBubbleVerticalPad)
    #expect(contentFrame.size.width == expectedContentWidth)
    #expect(contentFrame.size.height == 80)
    #expect(imagePlacement?.leadingX == backgroundFrame.minX)
    #expect(imagePlacement?.availableWidth == availableWidth)
    #expect(imagePlacement?.offsetY == 100)
    #expect(imagePlacement?.isUserAligned == true)
  }

  @Test func thinkingLayoutPlanCarriesCollapsedFooterGeometry() {
    let model = NativeRichMessageRowModel(
      messageID: "msg-2",
      speaker: "Claude",
      content: String(repeating: "thinking ", count: 90),
      thinking: nil,
      messageType: .thinking,
      renderMode: .markdown,
      timestamp: Date(),
      hasImages: false,
      images: [],
      isThinkingExpanded: false
    )
    let presentation = ConversationRichMessageLayout.presentation(for: model)

    let plan = ConversationRichMessageLayout.bodyLayoutPlan(
      totalWidth: 500,
      model: model,
      presentation: presentation,
      contentHeight: 120
    )

    guard case let .thinking(backgroundFrame, contentFrame, footerFrame, isCollapsed, fadeHeight) = plan else {
      Issue.record("Expected thinking layout plan")
      return
    }

    let availableWidth = min(
      500 - ConversationRichMessageLayout.laneHorizontalInset * 2,
      ConversationRichMessageLayout.thinkingRailMaxWidth
    )
    let expectedContentWidth = availableWidth - ConversationRichMessageLayout.thinkingHPad * 2

    #expect(backgroundFrame.origin.x == ConversationLayout.laneHorizontalInset)
    #expect(backgroundFrame.size.width == availableWidth)
    #expect(backgroundFrame.size.height == 178)
    #expect(contentFrame.origin.x == ConversationLayout.laneHorizontalInset + ConversationRichMessageLayout.thinkingHPad)
    #expect(contentFrame.origin.y == ConversationRichMessageLayout.thinkingVPadTop)
    #expect(contentFrame.size.width == expectedContentWidth)
    #expect(contentFrame.size.height == 120)
    #expect(footerFrame?.origin.y == 146)
    #expect(footerFrame?.size.height == ConversationRichMessageLayout.thinkingShowMoreHeight)
    #expect(isCollapsed)
    #expect(fadeHeight == ConversationRichMessageLayout.thinkingFadeHeight)
  }
}
