//
//  ConversationRichMessagePresentation.swift
//  OrbitDock
//
//  Shared rich-message presentation and layout helpers for the native
//  AppKit/UIKit conversation cells.
//

import SwiftUI

enum RichMessageSymbolWeight {
  case regular
  case medium
}

#if os(macOS)
  extension RichMessageSymbolWeight {
    var platformWeight: NSFont.Weight {
      switch self {
        case .regular: .regular
        case .medium: .medium
      }
    }
  }
#else
  extension RichMessageSymbolWeight {
    var platformWeight: UIImage.SymbolWeight {
      switch self {
        case .regular: .regular
        case .medium: .medium
      }
    }
  }
#endif

struct RichMessageHeaderSpec {
  let isVisible: Bool
  let isRightAligned: Bool
  let glyphSymbol: String
  let glyphColor: PlatformColor
  let glyphPointSize: CGFloat
  let glyphWeight: RichMessageSymbolWeight
  let glyphFrameSize: CGFloat
  let labelText: String?
  let labelAttributes: [NSAttributedString.Key: Any]?
}

enum RichMessageBodyChrome {
  case assistant
  case userBubble(horizontalPadding: CGFloat, verticalPadding: CGFloat, accentBarWidth: CGFloat)
  case steer(lineSpacing: CGFloat)
  case thinking(
    horizontalPadding: CGFloat,
    verticalTop: CGFloat,
    verticalBottom: CGFloat,
    footerHeight: CGFloat,
    fadeHeight: CGFloat
  )
  case error(
    horizontalPadding: CGFloat,
    verticalTop: CGFloat,
    verticalBottom: CGFloat,
    accentBarWidth: CGFloat
  )
}

struct RichMessagePresentation {
  let header: RichMessageHeaderSpec
  let contentStyle: ContentStyle
  let bodyChrome: RichMessageBodyChrome
  let railMaxWidth: CGFloat
  let thinkingButtonTitle: String?

  var bodyOriginY: CGFloat {
    header.isVisible
      ? ConversationRichMessageLayout.headerHeight + ConversationRichMessageLayout.headerToBodySpacing
      : 0
  }

  var actualHeaderHeight: CGFloat {
    header.isVisible ? ConversationRichMessageLayout.headerHeight : 0
  }

  var actualHeaderSpacing: CGFloat {
    header.isVisible ? ConversationRichMessageLayout.headerToBodySpacing : 0
  }

  var isUserAligned: Bool { header.isRightAligned }
}

@MainActor
enum ConversationRichMessageLayout {
  static let headerHeight: CGFloat = 20
  static let laneHorizontalInset = ConversationLayout.laneHorizontalInset
  static let metadataHorizontalInset = ConversationLayout.metadataHorizontalInset
  static let headerToBodySpacing = ConversationLayout.headerToBodySpacing
  static let entryBottomSpacing = ConversationLayout.entryBottomSpacing
  static let assistantRailMaxWidth = ConversationLayout.assistantRailMaxWidth
  static let thinkingRailMaxWidth = ConversationLayout.thinkingRailMaxWidth
  static let userRailMaxWidth = ConversationLayout.userRailMaxWidth

  static let userBubbleHorizontalPad: CGFloat = 14
  static let userBubbleVerticalPad: CGFloat = 10
  static let userAccentBarWidth: CGFloat = EdgeBar.width

  static let thinkingHPad: CGFloat = 16
  static let thinkingVPadTop: CGFloat = 14
  static let thinkingVPadBottom: CGFloat = 12
  static let thinkingShowMoreHeight: CGFloat = 32
  static let thinkingFadeHeight: CGFloat = 28

  static let errorHPad: CGFloat = 16
  static let errorVPadTop: CGFloat = 14
  static let errorVPadBottom: CGFloat = 12
  static let errorAccentBarWidth: CGFloat = EdgeBar.width

  static func presentation(for model: NativeRichMessageRowModel) -> RichMessagePresentation {
    let isThinking = model.messageType == .thinking
    let labelText: String? = model.messageType == .error ? model.speaker : nil
    let labelAttributes: [NSAttributedString.Key: Any]? = if labelText != nil {
      [
        .kern: 0.5 as CGFloat,
        .font: PlatformFont.systemFont(ofSize: TypeScale.chatLabel, weight: .semibold),
        .foregroundColor: model.speakerColor,
      ]
    } else {
      nil
    }

    let header = RichMessageHeaderSpec(
      isVisible: model.showHeader,
      isRightAligned: model.isUserAligned,
      glyphSymbol: model.glyphSymbol,
      glyphColor: model.glyphColor,
      glyphPointSize: isThinking ? 8 : 10,
      glyphWeight: isThinking ? .regular : .medium,
      glyphFrameSize: 20,
      labelText: labelText,
      labelAttributes: labelAttributes
    )

    if model.isUserAligned {
      return RichMessagePresentation(
        header: header,
        contentStyle: .standard,
        bodyChrome: .userBubble(
          horizontalPadding: userBubbleHorizontalPad,
          verticalPadding: userBubbleVerticalPad,
          accentBarWidth: userAccentBarWidth
        ),
        railMaxWidth: userRailMaxWidth,
        thinkingButtonTitle: nil
      )
    }

    switch model.messageType {
      case .steer:
        return RichMessagePresentation(
          header: header,
          contentStyle: .standard,
          bodyChrome: .steer(lineSpacing: 3),
          railMaxWidth: assistantRailMaxWidth,
          thinkingButtonTitle: nil
        )
      case .thinking:
        return RichMessagePresentation(
          header: header,
          contentStyle: .thinking,
          bodyChrome: .thinking(
            horizontalPadding: thinkingHPad,
            verticalTop: thinkingVPadTop,
            verticalBottom: thinkingVPadBottom,
            footerHeight: thinkingShowMoreHeight,
            fadeHeight: thinkingFadeHeight
          ),
          railMaxWidth: thinkingRailMaxWidth,
          thinkingButtonTitle: model.isThinkingLong
            ? (model.isThinkingExpanded ? "Show less" : "Show more\u{2026}")
            : nil
        )
      case .error:
        return RichMessagePresentation(
          header: header,
          contentStyle: .standard,
          bodyChrome: .error(
            horizontalPadding: errorHPad,
            verticalTop: errorVPadTop,
            verticalBottom: errorVPadBottom,
            accentBarWidth: errorAccentBarWidth
          ),
          railMaxWidth: assistantRailMaxWidth,
          thinkingButtonTitle: nil
        )
      case .assistant, .user, .shell:
        return RichMessagePresentation(
          header: header,
          contentStyle: .standard,
          bodyChrome: .assistant,
          railMaxWidth: assistantRailMaxWidth,
          thinkingButtonTitle: nil
        )
    }
  }

  static func contentWidth(for width: CGFloat, presentation: RichMessagePresentation) -> CGFloat {
    min(width - laneHorizontalInset * 2, presentation.railMaxWidth)
  }

  static func steerAttributedText(_ content: String, lineSpacing: CGFloat) -> NSAttributedString {
    let para = NSMutableParagraphStyle()
    para.lineSpacing = lineSpacing
    return NSAttributedString(string: content, attributes: [
      .font: PlatformFont.systemFont(ofSize: TypeScale.subhead).withItalic(),
      .foregroundColor: PlatformColor.secondaryLabelCompat,
      .paragraphStyle: para,
    ])
  }

  static func bodyHeight(
    for width: CGFloat,
    model: NativeRichMessageRowModel,
    blocks: [MarkdownBlock],
    imageHeightProvider: (CGFloat) -> CGFloat
  ) -> CGFloat {
    let presentation = presentation(for: model)
    let contentWidth = contentWidth(for: width, presentation: presentation)

    switch presentation.bodyChrome {
      case .assistant:
        let mdHeight = NativeMarkdownContentView.requiredHeight(
          for: blocks,
          width: contentWidth,
          style: presentation.contentStyle
        )
        return mdHeight + imageHeightProvider(contentWidth)

      case let .userBubble(horizontalPadding, verticalPadding, accentBarWidth):
        let innerWidth = contentWidth - horizontalPadding * 2 - accentBarWidth
        let mdHeight = NativeMarkdownContentView.requiredHeight(
          for: blocks,
          width: innerWidth,
          style: presentation.contentStyle
        )
        let bubbleHeight = mdHeight + verticalPadding * 2
        return bubbleHeight + imageHeightProvider(contentWidth)

      case let .steer(lineSpacing):
        let attrStr = steerAttributedText(model.content, lineSpacing: lineSpacing)
        return NativeMarkdownContentView.measureTextHeight(attrStr, width: contentWidth)

      case let .thinking(horizontalPadding, verticalTop, verticalBottom, footerHeight, _):
        let innerWidth = contentWidth - horizontalPadding * 2
        let mdHeight = NativeMarkdownContentView.requiredHeight(for: blocks, width: innerWidth, style: .thinking)
        let bottomZone = presentation.thinkingButtonTitle == nil ? 0 : footerHeight
        return verticalTop + mdHeight + verticalBottom + bottomZone

      case let .error(horizontalPadding, verticalTop, verticalBottom, accentBarWidth):
        let innerWidth = contentWidth - horizontalPadding * 2 - accentBarWidth
        let mdHeight = NativeMarkdownContentView.requiredHeight(
          for: blocks,
          width: innerWidth,
          style: presentation.contentStyle
        )
        return verticalTop + mdHeight + verticalBottom
    }
  }

  static func requiredHeight(
    for width: CGFloat,
    model: NativeRichMessageRowModel,
    blocks: [MarkdownBlock],
    imageHeightProvider: (CGFloat) -> CGFloat
  ) -> CGFloat {
    let presentation = presentation(for: model)
    let body = bodyHeight(
      for: width,
      model: model,
      blocks: blocks,
      imageHeightProvider: imageHeightProvider
    )
    return max(1, ceil(presentation.actualHeaderHeight + presentation.actualHeaderSpacing + body + entryBottomSpacing))
  }
}
