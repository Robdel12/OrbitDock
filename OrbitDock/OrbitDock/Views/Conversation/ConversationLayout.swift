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
  static let headerToBodySpacing: CGFloat = 8

  /// Vertical spacing between timeline entries (4pt grid).
  static let entryBottomSpacing: CGFloat = 16

  /// Max readable width for left-aligned assistant content.
  /// Capped at ~80 characters per line at 14.5pt SF Pro (Typography.md §Line Length).
  static let assistantRailMaxWidth: CGFloat = 820

  /// Max readable width for reasoning/thinking blocks (subordinate to assistant).
  static let thinkingRailMaxWidth: CGFloat = 880

  /// Max readable width for right-aligned user content.
  static let userRailMaxWidth: CGFloat = 1_000

  /// Chat turn stack spacing.
  static let turnVerticalSpacing: CGFloat = 20

  /// Tool-zone panel insets.
  static let toolZoneInnerHorizontalInset: CGFloat = 10
  static let toolZoneInnerVerticalInset: CGFloat = 6
  static let toolZoneOuterVerticalInset: CGFloat = 4

  // MARK: - Fixed Row Heights (macOS native rows — no SwiftUI measurement)

  /// Turn header: "TURN N" + status capsule + tool count
  static let turnHeaderHeight: CGFloat = 40

  /// Rollup summary: chevron + action count + tool breakdown chips
  static let rollupSummaryHeight: CGFloat = 40

  /// Compact tool row: glyph + summary + meta (4pt grid)
  static let compactToolRowHeight: CGFloat = 32

  /// "Load N earlier messages" button
  static let loadMoreHeight: CGFloat = 38

  /// "Showing N of M messages" label
  static let messageCountHeight: CGFloat = 24

  /// Bottom spacer below last row
  static let bottomSpacerHeight: CGFloat = 32

  #if os(macOS)
    static var backgroundPrimary: NSColor {
      NSColor(Color.backgroundPrimary)
    }
  #endif
}
