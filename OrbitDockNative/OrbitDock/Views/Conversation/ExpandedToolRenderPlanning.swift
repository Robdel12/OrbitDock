#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

import CoreGraphics
import Foundation

enum ExpandedToolPayloadSectionContentPlan: Equatable {
  case askUserQuestions([ExpandedToolLayout.AskUserQuestionItem])
  case structuredEntries([ExpandedToolLayout.StructuredPayloadEntry])
  case textLines([String])
}

struct ExpandedToolPayloadSectionPlan: Equatable {
  let title: String
  let content: ExpandedToolPayloadSectionContentPlan
}

struct ExpandedToolTodoRowMetrics: Equatable {
  let statusText: String
  let iconName: String
  let badgeWidth: CGFloat
  let textWidth: CGFloat
  let primaryHeight: CGFloat
  let secondaryHeight: CGFloat
  let rowHeight: CGFloat
}

enum ExpandedToolRenderPlanning {
  static func payloadSectionPlan(
    title: String,
    payload: String?,
    toolName: String? = nil
  ) -> ExpandedToolPayloadSectionPlan? {
    guard let payload, !payload.isEmpty else { return nil }

    if toolName?.lowercased() == "question",
       let questions = ExpandedToolLayout.askUserQuestionItems(from: payload)
    {
      return ExpandedToolPayloadSectionPlan(
        title: title,
        content: .askUserQuestions(questions)
      )
    }

    if let entries = ExpandedToolLayout.structuredPayloadEntries(from: payload) {
      return ExpandedToolPayloadSectionPlan(
        title: title,
        content: .structuredEntries(entries)
      )
    }

    return ExpandedToolPayloadSectionPlan(
      title: title,
      content: .textLines(ExpandedToolLayout.payloadDisplayLines(from: payload))
    )
  }

  static func todoRowMetrics(
    for item: NativeTodoItem,
    contentWidth: CGFloat
  ) -> ExpandedToolTodoRowMetrics {
    let statusText = item.status.label.uppercased()
    let badgeTextWidth = ceil(
      (statusText as NSString).size(withAttributes: [.font: ExpandedToolLayout.statsFont as Any]).width
    )
    let badgeWidth = min(
      ExpandedToolLayout.todoBadgeMaxWidth,
      max(
        ExpandedToolLayout.todoBadgeMinWidth,
        badgeTextWidth + ExpandedToolLayout.todoBadgeSidePadding * 2
      )
    )

    let rowWidth = contentWidth
    let iconAndGap = ExpandedToolLayout.todoIconWidth + 8
    let textX = ExpandedToolLayout.todoRowHorizontalPadding + iconAndGap
    let badgeX = rowWidth - ExpandedToolLayout.todoRowHorizontalPadding - badgeWidth
    let textWidth = max(90, badgeX - textX - 8)
    let primaryHeight = ExpandedToolLayout.measuredTextHeight(
      item.primaryText,
      font: ExpandedToolLayout.todoTitleFont,
      maxWidth: textWidth
    )
    let secondaryHeight = item.secondaryText.map {
      ExpandedToolLayout.measuredTextHeight(
        $0,
        font: ExpandedToolLayout.todoSecondaryFont,
        maxWidth: textWidth
      )
    } ?? 0
    let textHeight = primaryHeight + (secondaryHeight > 0 ? 2 + secondaryHeight : 0)
    let rowHeight = max(
      ExpandedToolLayout.todoBadgeHeight + ExpandedToolLayout.todoRowVerticalPadding * 2,
      textHeight + ExpandedToolLayout.todoRowVerticalPadding * 2
    )

    return ExpandedToolTodoRowMetrics(
      statusText: statusText,
      iconName: todoStatusIconName(for: item.status),
      badgeWidth: badgeWidth,
      textWidth: textWidth,
      primaryHeight: primaryHeight,
      secondaryHeight: secondaryHeight,
      rowHeight: rowHeight
    )
  }

  static func todoStatusIconName(for status: NativeTodoStatus) -> String {
    switch status {
      case .pending: "circle"
      case .inProgress: "arrow.triangle.2.circlepath"
      case .completed: "checkmark.circle.fill"
      case .blocked: "exclamationmark.triangle.fill"
      case .canceled: "xmark.circle.fill"
      case .unknown: "questionmark.circle"
    }
  }
}
