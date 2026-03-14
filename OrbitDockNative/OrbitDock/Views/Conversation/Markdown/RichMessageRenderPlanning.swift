import CoreGraphics
import Foundation

enum RichMessageRenderableContent {
  case markdown(blocks: [MarkdownBlock], style: ContentStyle)
  case attributedText(NSAttributedString)
}

struct RichMessageBodyRenderPlan {
  let bodyHeight: CGFloat
  let layoutPlan: RichMessageBodyLayoutPlan
  let content: RichMessageRenderableContent
}

struct StreamingRichMessageUpdateState {
  let presentation: RichMessagePresentation
  let bodyHeight: CGFloat
  let layoutPlan: RichMessageBodyLayoutPlan
  let attributedText: NSAttributedString
}

struct RichMessageCellRenderState {
  let presentation: RichMessagePresentation
  let blocks: [MarkdownBlock]
  let body: RichMessageBodyRenderPlan
  let totalHeight: CGFloat
}

@MainActor
enum RichMessageRenderPlanning {
  static func parsedBlocks(
    for model: NativeRichMessageRowModel,
    presentation: RichMessagePresentation
  ) -> [MarkdownBlock] {
    guard !model.usesStreamingTextRenderer else { return [] }
    return MarkdownSystemParser.parse(model.displayContent, style: presentation.contentStyle)
  }

  static func requiredHeight(
    for width: CGFloat,
    model: NativeRichMessageRowModel,
    blocks: [MarkdownBlock],
    imageHeightProvider: (CGFloat) -> CGFloat
  ) -> CGFloat {
    ConversationRichMessageSupport.measureHeight(
      for: width,
      model: model,
      blocks: blocks,
      imageHeightProvider: imageHeightProvider
    ).totalHeight
  }

  static func renderState(
    for width: CGFloat,
    model: NativeRichMessageRowModel,
    imageHeightProvider: (CGFloat) -> CGFloat
  ) -> RichMessageCellRenderState {
    let presentation = ConversationRichMessageLayout.presentation(for: model)
    let blocks = parsedBlocks(for: model, presentation: presentation)
    let body = bodyRenderPlan(
      for: model,
      presentation: presentation,
      width: width,
      blocks: blocks,
      imageHeightProvider: imageHeightProvider
    )
    let totalHeight = requiredHeight(
      for: width,
      model: model,
      blocks: blocks,
      imageHeightProvider: imageHeightProvider
    )

    return RichMessageCellRenderState(
      presentation: presentation,
      blocks: blocks,
      body: body,
      totalHeight: totalHeight
    )
  }

  static func bodyRenderPlan(
    for model: NativeRichMessageRowModel,
    presentation: RichMessagePresentation,
    width: CGFloat,
    blocks: [MarkdownBlock],
    imageHeightProvider: (CGFloat) -> CGFloat
  ) -> RichMessageBodyRenderPlan {
    let contentWidth = ConversationRichMessageLayout.contentWidth(for: width, presentation: presentation)

    let content: RichMessageRenderableContent
    let contentHeight: CGFloat

    switch presentation.bodyChrome {
      case .assistant:
        if model.usesStreamingTextRenderer {
          let attributedText = ConversationRichMessageLayout.streamingAttributedText(
            for: model,
            style: presentation.contentStyle
          )
          content = .attributedText(attributedText)
          contentHeight = NativeMarkdownContentView.measureTextHeight(attributedText, width: contentWidth)
        } else {
          content = .markdown(blocks: blocks, style: presentation.contentStyle)
          contentHeight = NativeMarkdownContentView.requiredHeight(
            for: blocks,
            width: contentWidth,
            style: presentation.contentStyle
          )
        }

      case let .userBubble(horizontalPadding, _, accentBarWidth):
        let innerWidth = contentWidth - horizontalPadding * 2 - accentBarWidth
        content = .markdown(blocks: blocks, style: presentation.contentStyle)
        contentHeight = NativeMarkdownContentView.requiredHeight(
          for: blocks,
          width: innerWidth,
          style: presentation.contentStyle
        )

      case let .steer(lineSpacing):
        let attributedText = ConversationRichMessageLayout.steerAttributedText(
          model.content,
          lineSpacing: lineSpacing
        )
        content = .attributedText(attributedText)
        contentHeight = NativeMarkdownContentView.measureTextHeight(attributedText, width: contentWidth)

      case let .thinking(horizontalPadding, _, _, _, _):
        let innerWidth = contentWidth - horizontalPadding * 2
        if model.usesStreamingTextRenderer {
          let attributedText = ConversationRichMessageLayout.streamingAttributedText(for: model, style: .thinking)
          content = .attributedText(attributedText)
          contentHeight = NativeMarkdownContentView.measureTextHeight(attributedText, width: innerWidth)
        } else {
          content = .markdown(blocks: blocks, style: .thinking)
          contentHeight = NativeMarkdownContentView.requiredHeight(for: blocks, width: innerWidth, style: .thinking)
        }

      case let .error(horizontalPadding, _, _, accentBarWidth):
        let innerWidth = contentWidth - horizontalPadding * 2 - accentBarWidth
        content = .markdown(blocks: blocks, style: presentation.contentStyle)
        contentHeight = NativeMarkdownContentView.requiredHeight(
          for: blocks,
          width: innerWidth,
          style: presentation.contentStyle
        )
    }

    let layoutPlan = ConversationRichMessageLayout.bodyLayoutPlan(
      totalWidth: width,
      model: model,
      presentation: presentation,
      contentHeight: contentHeight
    )

    let bodyHeight = ConversationRichMessageLayout.bodyHeight(
      for: width,
      model: model,
      blocks: blocks,
      imageHeightProvider: imageHeightProvider
    )

    return RichMessageBodyRenderPlan(
      bodyHeight: bodyHeight,
      layoutPlan: layoutPlan,
      content: content
    )
  }

  static func streamingUpdateState(
    for width: CGFloat,
    model: NativeRichMessageRowModel,
    imageHeightProvider: (CGFloat) -> CGFloat
  ) -> StreamingRichMessageUpdateState? {
    guard model.usesStreamingTextRenderer else { return nil }

    let presentation = ConversationRichMessageLayout.presentation(for: model)
    let attributedText = ConversationRichMessageLayout.streamingAttributedText(
      for: model,
      style: presentation.contentStyle
    )
    let contentWidth = ConversationRichMessageLayout.contentWidth(for: width, presentation: presentation)

    let contentHeight: CGFloat
    switch presentation.bodyChrome {
      case .assistant:
        contentHeight = NativeMarkdownContentView.measureTextHeight(attributedText, width: contentWidth)

      case let .thinking(horizontalPadding, _, _, _, _):
        let innerWidth = contentWidth - horizontalPadding * 2
        contentHeight = NativeMarkdownContentView.measureTextHeight(attributedText, width: innerWidth)

      default:
        return nil
    }

    let layoutPlan = ConversationRichMessageLayout.bodyLayoutPlan(
      totalWidth: width,
      model: model,
      presentation: presentation,
      contentHeight: contentHeight
    )

    let bodyHeight = ConversationRichMessageLayout.bodyHeight(
      for: width,
      model: model,
      blocks: [],
      imageHeightProvider: imageHeightProvider
    )

    return StreamingRichMessageUpdateState(
      presentation: presentation,
      bodyHeight: bodyHeight,
      layoutPlan: layoutPlan,
      attributedText: attributedText
    )
  }
}
