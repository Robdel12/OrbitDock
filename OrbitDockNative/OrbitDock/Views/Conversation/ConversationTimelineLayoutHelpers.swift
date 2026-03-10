//
//  ConversationTimelineLayoutHelpers.swift
//  OrbitDock
//
//  Shared timeline layout helpers used by both macOS and iOS conversation views.
//  Keeps row grouping, spacing, and strip-row metrics in one place so the two
//  renderers do not drift on behavior or geometry.
//

import CoreGraphics
import SwiftUI

nonisolated struct ConversationCardSpacing: Hashable, Sendable {
  let topInset: CGFloat
  let bottomInset: CGFloat
  let heightExtra: CGFloat

  static let none = Self(topInset: 0, bottomInset: 0, heightExtra: 0)
}

@MainActor
enum ConversationStripRowMetrics {
  static let verticalInset: CGFloat = 3
  static let accentLeadingInset: CGFloat = 5
  static let accentVerticalInset: CGFloat = 6
  static let accentWidth: CGFloat = EdgeBar.width
  static let iconSize: CGFloat = 16
  static let iconTopInset: CGFloat = 9
  static let disclosureWidth: CGFloat = 10
  static let chevronWidth: CGFloat = 8
  static let chevronHeight: CGFloat = 10
  static let detailTopSpacing: CGFloat = 3
  static let diffBarHeight: CGFloat = 3

  static func totalHeight(forContentHeight contentHeight: CGFloat) -> CGFloat {
    contentHeight + verticalInset * 2
  }
}

@MainActor
enum ConversationTimelineLayoutHelpers {
  static func turnHeaderHeight(for row: TimelineRow) -> CGFloat {
    if case let .turnHeader(_, turnNumber, _) = row.payload, turnNumber == 1 {
      return ConversationLayout.firstTurnHeaderHeight
    }
    return ConversationLayout.turnHeaderHeight
  }

  static func cardPosition(
    for index: Int,
    rows: [TimelineRow],
    messageLookup: (String) -> TranscriptMessage?
  ) -> CardPosition {
    guard index >= 0, index < rows.count else { return .none }

    let timelineRow = rows[index]
    guard isCardEligible(timelineRow, messageLookup: messageLookup) else { return .none }

    let prevEligible = (0 ..< index).reversed().first { candidate in
      isCardEligible(rows[candidate], messageLookup: messageLookup)
    }
    let nextEligible = ((index + 1) ..< rows.count).first { candidate in
      isCardEligible(rows[candidate], messageLookup: messageLookup)
    }

    let hasPrevInCard: Bool = if let prevEligible {
      !containsTurnHeader(in: rows, from: prevEligible + 1, to: index)
    } else {
      false
    }

    let hasNextInCard: Bool = if let nextEligible {
      !containsTurnHeader(in: rows, from: index + 1, to: nextEligible)
    } else {
      false
    }

    switch (hasPrevInCard, hasNextInCard) {
      case (false, false):
        return .solo
      case (false, true):
        return .top
      case (true, true):
        return .middle
      case (true, false):
        return .bottom
    }
  }

  static func cardSpacing(for position: CardPosition) -> ConversationCardSpacing {
    let edge = ConversationLayout.cardEdgeSpacing
    let inset = ConversationLayout.cardVerticalInset
    let tight = ConversationLayout.intraCardSpacing

    switch position {
      case .top:
        return ConversationCardSpacing(topInset: edge + inset, bottomInset: 0, heightExtra: edge + inset + tight / 2)
      case .middle:
        return ConversationCardSpacing(topInset: 0, bottomInset: 0, heightExtra: tight)
      case .bottom:
        return ConversationCardSpacing(topInset: 0, bottomInset: edge + inset, heightExtra: edge + inset + tight / 2)
      case .solo:
        return ConversationCardSpacing(
          topInset: edge + inset,
          bottomInset: edge + inset,
          heightExtra: (edge + inset) * 2
        )
      case .none:
        return .none
    }
  }

  static func cardSpacing(
    for index: Int,
    rows: [TimelineRow],
    messageLookup: (String) -> TranscriptMessage?
  ) -> ConversationCardSpacing {
    cardSpacing(for: cardPosition(for: index, rows: rows, messageLookup: messageLookup))
  }

  private static func isCardEligible(
    _ row: TimelineRow,
    messageLookup: (String) -> TranscriptMessage?
  ) -> Bool {
    switch row.kind {
      case .tool, .rollupSummary, .liveProgress:
        return true
      case .message:
        guard case let .message(messageID, _) = row.payload,
              let message = messageLookup(messageID)
        else {
          return false
        }
        return message.type != .user && message.type != .steer
      case .turnHeader, .loadMore, .messageCount, .liveIndicator,
           .approvalCard, .bottomSpacer, .collapsedTurn:
        return false
    }
  }

  private static func containsTurnHeader(
    in rows: [TimelineRow],
    from start: Int,
    to end: Int
  ) -> Bool {
    guard start < end else { return false }
    return rows[start ..< end].contains { $0.kind == .turnHeader }
  }
}
