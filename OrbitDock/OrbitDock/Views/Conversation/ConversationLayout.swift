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
  static let laneHorizontalInset: CGFloat = 16

  /// Header row inset for timestamp/glyph/speaker metadata rows.
  static let metadataHorizontalInset: CGFloat = 12

  /// Vertical spacing between a role header row and its body (4pt grid).
  static let headerToBodySpacing: CGFloat = 4

  /// Vertical spacing between timeline entries (4pt grid).
  static let entryBottomSpacing: CGFloat = 12

  /// Max readable width for left-aligned assistant content.
  /// Capped at ~80 characters per line at 14.5pt SF Pro (Typography.md §Line Length).
  static let assistantRailMaxWidth: CGFloat = 880

  /// Max readable width for reasoning/thinking blocks (subordinate to assistant).
  static let thinkingRailMaxWidth: CGFloat = 880

  /// Max readable width for right-aligned user content.
  static let userRailMaxWidth: CGFloat = 1_000

  /// Chat turn stack spacing.
  static let turnVerticalSpacing: CGFloat = 16

  /// Tool-zone panel insets.
  static let toolZoneInnerHorizontalInset: CGFloat = 10
  static let toolZoneInnerVerticalInset: CGFloat = 6
  static let toolZoneOuterVerticalInset: CGFloat = 4

  // MARK: - Fixed Row Heights (macOS native rows — no SwiftUI measurement)

  /// Turn header: subtle breath mark between turns
  static let turnHeaderHeight: CGFloat = 24

  /// First turn header: minimal spacer (no visual break before first message)
  static let firstTurnHeaderHeight: CGFloat = 8

  /// Rollup summary: chevron + comma-separated tool counts
  static let rollupSummaryHeight: CGFloat = 28

  /// Compact tool row: glyph + summary + meta (4pt grid)
  static let compactToolRowHeight: CGFloat = 28

  /// "Load N earlier messages" button
  static let loadMoreHeight: CGFloat = 38

  /// "Showing N of M messages" label
  static let messageCountHeight: CGFloat = 24

  /// Bottom status row ("Working", "Your turn", "Permission")
  static let liveIndicatorHeight: CGFloat = 36

  /// Bottom spacer below last row
  static let bottomSpacerHeight: CGFloat = 32

  #if os(macOS)
    static var backgroundPrimary: NSColor {
      NSColor(Color.backgroundPrimary)
    }
  #endif
}
