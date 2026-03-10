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

enum ExpandedToolPayloadRenderItem: Equatable {
  case questionHeader(String)
  case questionPrompt(String)
  case questionOption(label: String, description: String?)
  case structuredEntry(key: String, value: String)
  case textLine(String)
  case spacer(CGFloat)
}

struct ExpandedToolPayloadSectionRenderPlan: Equatable {
  let title: String
  let items: [ExpandedToolPayloadRenderItem]
}

enum ExpandedToolPayloadTextStyle: Equatable {
  case questionHeader
  case questionPrompt
  case questionOption
  case questionDetail
  case structuredEntry
  case textLine
}

enum ExpandedToolPayloadTextContent: Equatable {
  case plain(String)
  case structuredEntry(key: String, value: String)
}

struct ExpandedToolPayloadTextRowPlan: Equatable {
  let style: ExpandedToolPayloadTextStyle
  let content: ExpandedToolPayloadTextContent
  let leadingInset: CGFloat
  let widthAdjustment: CGFloat
  let topInset: CGFloat
  let bottomSpacing: CGFloat
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

  static func payloadSectionRenderPlan(
    title: String,
    payload: String?,
    toolName: String? = nil
  ) -> ExpandedToolPayloadSectionRenderPlan? {
    guard let section = payloadSectionPlan(title: title, payload: payload, toolName: toolName) else {
      return nil
    }

    var items: [ExpandedToolPayloadRenderItem] = []

    switch section.content {
      case let .askUserQuestions(questions):
        for (index, question) in questions.enumerated() {
          if let header = question.header?.trimmingCharacters(in: .whitespacesAndNewlines), !header.isEmpty {
            items.append(.questionHeader(header.uppercased()))
          }

          items.append(.questionPrompt(question.question))

          if !question.options.isEmpty {
            items.append(.spacer(6))

            for option in question.options {
              items.append(.questionOption(label: option.label, description: option.description))
              items.append(.spacer(5))
            }

            items.removeLast()
          }

          if index < questions.count - 1 {
            items.append(.spacer(8))
          }
        }

      case let .structuredEntries(entries):
        items.append(contentsOf: entries.map { .structuredEntry(key: $0.keyPath, value: $0.value) })

      case let .textLines(lines):
        items.append(contentsOf: lines.map(ExpandedToolPayloadRenderItem.textLine))
    }

    return ExpandedToolPayloadSectionRenderPlan(title: section.title, items: items)
  }

  static func payloadSectionTextRows(
    title: String,
    payload: String?,
    toolName: String? = nil
  ) -> [ExpandedToolPayloadTextRowPlan] {
    guard let section = payloadSectionRenderPlan(title: title, payload: payload, toolName: toolName) else {
      return []
    }

    return payloadTextRows(for: section.items)
  }

  static func payloadTextRows(
    for items: [ExpandedToolPayloadRenderItem]
  ) -> [ExpandedToolPayloadTextRowPlan] {
    items.flatMap { item in
      payloadTextRows(for: item)
    }
  }

  private static func payloadTextRows(
    for item: ExpandedToolPayloadRenderItem
  ) -> [ExpandedToolPayloadTextRowPlan] {
    switch item {
      case let .questionHeader(text):
        return [
          ExpandedToolPayloadTextRowPlan(
            style: .questionHeader,
            content: .plain(text),
            leadingInset: 0,
            widthAdjustment: 0,
            topInset: 0,
            bottomSpacing: 3
          )
        ]

      case let .questionPrompt(text):
        return [
          ExpandedToolPayloadTextRowPlan(
            style: .questionPrompt,
            content: .plain(text),
            leadingInset: 0,
            widthAdjustment: 0,
            topInset: 0,
            bottomSpacing: 0
          )
        ]

      case let .questionOption(label, description):
        var rows = [
          ExpandedToolPayloadTextRowPlan(
            style: .questionOption,
            content: .plain("• \(label)"),
            leadingInset: 0,
            widthAdjustment: 0,
            topInset: 0,
            bottomSpacing: 0
          )
        ]

        if let description, !description.isEmpty {
          rows.append(
            ExpandedToolPayloadTextRowPlan(
              style: .questionDetail,
              content: .plain(description),
              leadingInset: 14,
              widthAdjustment: 14,
              topInset: 2,
              bottomSpacing: 2
            )
          )
        }

        return rows

      case let .structuredEntry(key, value):
        return [
          ExpandedToolPayloadTextRowPlan(
            style: .structuredEntry,
            content: .structuredEntry(key: key, value: value),
            leadingInset: 0,
            widthAdjustment: 0,
            topInset: 0,
            bottomSpacing: 0
          )
        ]

      case let .textLine(text):
        return [
          ExpandedToolPayloadTextRowPlan(
            style: .textLine,
            content: .plain(text),
            leadingInset: 0,
            widthAdjustment: 0,
            topInset: 0,
            bottomSpacing: 0
          )
        ]

      case let .spacer(spacing):
        return [
          ExpandedToolPayloadTextRowPlan(
            style: .textLine,
            content: .plain(""),
            leadingInset: 0,
            widthAdjustment: 0,
            topInset: 0,
            bottomSpacing: spacing
          )
        ]
    }
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
