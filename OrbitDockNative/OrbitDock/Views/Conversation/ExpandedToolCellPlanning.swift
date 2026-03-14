#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

import CoreGraphics
import Foundation

struct ExpandedToolCardLayoutPlan: Equatable {
  let inset: CGFloat
  let cardWidth: CGFloat
  let headerHeight: CGFloat
  let contentHeight: CGFloat
  let visibleContentHeight: CGFloat
  let totalHeight: CGFloat
  let cardFrame: CGRect
  let accentFrame: CGRect
  let headerDividerFrame: CGRect?
  let contentBackgroundFrame: CGRect?
  let contentScrollFrame: CGRect
  let iconFrame: CGRect
  let contentContainerFrame: CGRect
  let header: ExpandedToolHeaderLayoutPlan
  let progressFrame: CGRect?
  let cancelFrame: CGRect?
  let chevronFrame: CGRect?
  let durationFrame: CGRect?
}

struct ExpandedToolHeaderLayoutPlan: Equatable {
  let titleFrame: CGRect
  let subtitleFrame: CGRect?
  let statsFrame: CGRect?
}

struct ExpandedToolPayloadLabelPlan: Equatable {
  let attributedKey: String?
  let attributedValue: String?
  let text: String?
  let style: ExpandedToolPayloadTextStyle
  let frame: CGRect
}

enum ExpandedToolCellPlanning {
  static func cardLayoutPlan(for model: NativeExpandedToolModel, width: CGFloat) -> ExpandedToolCardLayoutPlan {
    let inset = ExpandedToolLayout.laneHorizontalInset
    let cardWidth = width - inset * 2
    let headerHeight = ExpandedToolLayout.headerHeight(for: model, cardWidth: cardWidth)
    let contentHeight = ExpandedToolLayout.contentHeight(for: model, cardWidth: cardWidth)
    let visibleContentHeight = ExpandedToolLayout.visibleContentHeight(for: contentHeight)
    let totalHeight = ExpandedToolLayout.requiredHeight(for: width, model: model)

    let dividerX = ExpandedToolLayout.accentBarWidth
    let dividerWidth = cardWidth - ExpandedToolLayout.accentBarWidth
    let iconFrame = CGRect(
      x: ExpandedToolLayout.accentBarWidth + ExpandedToolLayout.headerHPad,
      y: ExpandedToolLayout.headerVPad,
      width: 20,
      height: 20
    )

    let header = headerLayoutPlan(
      for: model,
      cardWidth: cardWidth,
      headerHeight: headerHeight,
      durationWidth: model.duration.flatMap { durationWidth(for: $0, isVisible: !model.isInProgress && !model.canCancel) },
      showsChevron: !model.isInProgress && !model.canCancel
    )

    let progressFrame: CGRect?
    if model.isInProgress {
      let spinnerX = model.canCancel
        ? cardWidth - ExpandedToolLayout.headerHPad - 72
        : cardWidth - ExpandedToolLayout.headerHPad - 16
      progressFrame = CGRect(x: spinnerX, y: ExpandedToolLayout.headerVPad + 2, width: 16, height: 16)
    } else {
      progressFrame = nil
    }

    let cancelFrame: CGRect?
    if model.canCancel {
      cancelFrame = CGRect(
        x: cardWidth - ExpandedToolLayout.headerHPad - 52,
        y: ExpandedToolLayout.headerVPad,
        width: 52,
        height: 20
      )
    } else {
      cancelFrame = nil
    }

    let chevronFrame: CGRect?
    if !model.isInProgress, !model.canCancel {
      chevronFrame = CGRect(
        x: cardWidth - ExpandedToolLayout.headerHPad - 12,
        y: ExpandedToolLayout.headerVPad + 3,
        width: 12,
        height: 12
      )
    } else {
      chevronFrame = nil
    }

    let durationFrame: CGRect?
    if let duration = model.duration, !model.isInProgress, !model.canCancel {
      let width = durationWidth(for: duration, isVisible: true) ?? 0
      durationFrame = CGRect(
        x: cardWidth - ExpandedToolLayout.headerHPad - 12 - 8 - width,
        y: ExpandedToolLayout.headerVPad + 2,
        width: width,
        height: 16
      )
    } else {
      durationFrame = nil
    }

    return ExpandedToolCardLayoutPlan(
      inset: inset,
      cardWidth: cardWidth,
      headerHeight: headerHeight,
      contentHeight: contentHeight,
      visibleContentHeight: visibleContentHeight,
      totalHeight: totalHeight,
      cardFrame: CGRect(x: inset, y: 0, width: cardWidth, height: totalHeight),
      accentFrame: CGRect(x: 0, y: 0, width: ExpandedToolLayout.accentBarWidth, height: totalHeight),
      headerDividerFrame: visibleContentHeight > 0 ? CGRect(x: dividerX, y: headerHeight, width: dividerWidth, height: 1) : nil,
      contentBackgroundFrame: visibleContentHeight > 0
        ? CGRect(x: dividerX, y: headerHeight + 1, width: dividerWidth, height: visibleContentHeight) : nil,
      contentScrollFrame: CGRect(x: dividerX, y: headerHeight + 1, width: dividerWidth, height: visibleContentHeight),
      iconFrame: iconFrame,
      contentContainerFrame: CGRect(x: 0, y: 0, width: cardWidth, height: contentHeight),
      header: header,
      progressFrame: progressFrame,
      cancelFrame: cancelFrame,
      chevronFrame: chevronFrame,
      durationFrame: durationFrame
    )
  }

  static func payloadLabelPlan(
    for row: ExpandedToolPayloadTextRowPlan,
    containerWidth: CGFloat
  ) -> ExpandedToolPayloadLabelPlan {
    let textWidth = containerWidth - ExpandedToolLayout.headerHPad * 2
    let labelWidth = textWidth - row.widthAdjustment
    let height = payloadRowHeight(row, maxWidth: labelWidth)
    let frame = CGRect(
      x: ExpandedToolLayout.headerHPad + row.leadingInset,
      y: 0,
      width: labelWidth,
      height: height
    )

    switch row.content {
      case let .structuredEntry(key, value):
        return ExpandedToolPayloadLabelPlan(
          attributedKey: key,
          attributedValue: value,
          text: nil,
          style: .structuredEntry,
          frame: frame
        )

      case let .plain(text):
        return ExpandedToolPayloadLabelPlan(
          attributedKey: nil,
          attributedValue: nil,
          text: text.isEmpty ? " " : text,
          style: row.style,
          frame: frame
        )
    }
  }

  static func payloadRowHeight(_ row: ExpandedToolPayloadTextRowPlan, maxWidth: CGFloat) -> CGFloat {
    switch row.content {
      case let .structuredEntry(key, value):
        return ExpandedToolLayout.measuredTextHeight(
          "\(key): \(value)",
          font: ExpandedToolLayout.codeFont,
          maxWidth: maxWidth
        )

      case let .plain(text):
        return ExpandedToolLayout.measuredTextHeight(
          text.isEmpty ? " " : text,
          font: payloadFont(for: row.style),
          maxWidth: maxWidth
        )
    }
  }

  private static func headerLayoutPlan(
    for model: NativeExpandedToolModel,
    cardWidth: CGFloat,
    headerHeight: CGFloat,
    durationWidth: CGFloat?,
    showsChevron: Bool
  ) -> ExpandedToolHeaderLayoutPlan {
    let leftEdge = ExpandedToolLayout.accentBarWidth + ExpandedToolLayout.headerHPad + 20 + 8
    let rightEdge = cardWidth - ExpandedToolLayout.headerHPad - 12 - 8 - 60
    let plan = ExpandedToolHeaderPlanning.plan(for: model)
    let titleWidth = max(60, rightEdge - leftEdge)

    let titleFrame: CGRect
    let subtitleFrame: CGRect?
    if plan.subtitle != nil {
      titleFrame = CGRect(x: leftEdge, y: ExpandedToolLayout.headerVPad, width: titleWidth, height: 18)
      subtitleFrame = CGRect(x: leftEdge, y: ExpandedToolLayout.headerVPad + 18, width: titleWidth, height: 16)
    } else if case .bash = model.content {
      let titleHeight = max(18, headerHeight - ExpandedToolLayout.headerVPad * 2)
      titleFrame = CGRect(x: leftEdge, y: ExpandedToolLayout.headerVPad, width: titleWidth, height: titleHeight)
      subtitleFrame = nil
    } else {
      titleFrame = CGRect(x: leftEdge, y: ExpandedToolLayout.headerVPad + 4, width: titleWidth, height: 18)
      subtitleFrame = nil
    }

    let statsFrame: CGRect?
    if let statsText = plan.statsText {
      let statsWidth = textWidth(
        statsText,
        font: ExpandedToolLayout.statsFont
      )
      let durationOffset = durationWidth.map { $0 + 8 } ?? 0
      let chevronOffset: CGFloat = showsChevron ? 12 + 8 : 0
      let x = cardWidth - ExpandedToolLayout.headerHPad - chevronOffset - durationOffset - statsWidth
      statsFrame = CGRect(x: x, y: ExpandedToolLayout.headerVPad + 2, width: statsWidth, height: 16)
    } else {
      statsFrame = nil
    }

    return ExpandedToolHeaderLayoutPlan(
      titleFrame: titleFrame,
      subtitleFrame: subtitleFrame,
      statsFrame: statsFrame
    )
  }

  private static func durationWidth(for text: String, isVisible: Bool) -> CGFloat? {
    guard isVisible else { return nil }
    return textWidth(text, font: ExpandedToolLayout.statsFont)
  }

  private static func textWidth(_ text: String, font: PlatformFont) -> CGFloat {
    ceil((text as NSString).size(withAttributes: [.font: font as Any]).width)
  }
  private static func payloadFont(for style: ExpandedToolPayloadTextStyle) -> PlatformFont {
    switch style {
      case .questionHeader:
        PlatformFont.systemFont(ofSize: TypeScale.mini, weight: .bold)
      case .questionPrompt:
        PlatformFont.systemFont(ofSize: TypeScale.body, weight: .semibold)
      case .questionOption:
        PlatformFont.systemFont(ofSize: TypeScale.caption, weight: .medium)
      case .questionDetail:
        PlatformFont.systemFont(ofSize: TypeScale.meta, weight: .regular)
      case .structuredEntry, .textLine:
        ExpandedToolLayout.codeFont
    }
  }
}
