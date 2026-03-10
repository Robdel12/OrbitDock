//
//  ConversationLayout.swift
//  OrbitDock
//
//  Shared layout metrics for the conversation timeline.
//

import SwiftUI

#if os(macOS)
  import AppKit
#endif

enum ConversationLayout {
  /// Horizontal gutter between rail edge and timeline content.
  static let railHorizontalInset: CGFloat = 16

  /// Maximum readable width of the conversation rail.
  static let railMaxWidth: CGFloat = 1_800

  /// Left/right lane padding used by assistant/tool blocks and user bubbles.
  static let laneHorizontalInset: CGFloat = 20

  /// Header row inset for timestamp/glyph/speaker metadata rows.
  static let metadataHorizontalInset: CGFloat = 12

  /// Vertical spacing between a role header row and its body (4pt grid).
  static let headerToBodySpacing: CGFloat = 6

  /// Vertical spacing between timeline entries (4pt grid).
  static let entryBottomSpacing: CGFloat = 6

  /// Max readable width for left-aligned assistant content.
  /// Capped at ~80 characters per line at 14.5pt SF Pro (Typography.md §Line Length).
  static let assistantRailMaxWidth: CGFloat = 880

  /// Max readable width for reasoning/thinking blocks (subordinate to assistant).
  static let thinkingRailMaxWidth: CGFloat = 880

  /// Max readable width for right-aligned user content.
  static let userRailMaxWidth: CGFloat = 1_000

  // MARK: - Card Spacing (Rhythm)

  /// Tight spacing between rows inside a card group (tool → tool).
  static let intraCardSpacing: CGFloat = 2

  /// Medium spacing between card group edges and surrounding content.
  static let cardEdgeSpacing: CGFloat = 8

  // MARK: - Fixed Row Heights (macOS native rows — no SwiftUI measurement)

  /// Turn header: section divider between turns
  static let turnHeaderHeight: CGFloat = 36

  /// First turn header: minimal spacer (no visual break before first message)
  static let firstTurnHeaderHeight: CGFloat = 12

  /// Compact tool row: strip card base height (3+3 strip padding + 34 content)
  static let compactToolRowHeight: CGFloat = 40

  /// "Load N earlier messages" button
  static let loadMoreHeight: CGFloat = 44

  /// "Showing N of M messages" label
  static let messageCountHeight: CGFloat = 28

  /// Bottom status row ("Working", "Your turn", "Permission")
  #if os(iOS)
    static let liveIndicatorHeight: CGFloat = 36
  #else
    static let liveIndicatorHeight: CGFloat = 44
  #endif

  /// Bottom spacer below last row
  #if os(iOS)
    static let bottomSpacerHeight: CGFloat = 16
  #else
    static let bottomSpacerHeight: CGFloat = 48
  #endif

  // MARK: - Turn Cards

  /// Corner radius for turn card backgrounds
  static let cardCornerRadius: CGFloat = 12

  /// Horizontal padding inside turn cards
  static let cardHorizontalInset: CGFloat = 8

  /// Card background inset from row edge (top/bottom of card groups)
  static let cardVerticalInset: CGFloat = 4

  // MARK: - Activity Capsules

  /// Activity capsule row height
  static let activityCapsuleHeight: CGFloat = 36

  /// Activity capsule corner radius (pill shape)
  static let capsuleCornerRadius: CGFloat = 16

  // MARK: - Focus Mode

  /// Collapsed turn row height
  static let collapsedTurnHeight: CGFloat = 44

  // MARK: - Live Progress

  /// Live progress bar row height
  #if os(iOS)
    static let liveProgressHeight: CGFloat = 36
  #else
    static let liveProgressHeight: CGFloat = 44
  #endif

  #if os(macOS)
    static var backgroundPrimary: NSColor {
      NSColor(Color.backgroundPrimary)
    }
  #endif
}
