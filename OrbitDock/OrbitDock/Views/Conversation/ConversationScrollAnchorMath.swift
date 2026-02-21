//
//  ConversationScrollAnchorMath.swift
//  OrbitDock
//
//  Pure helpers for prepend anchor capture/restore math.
//

import CoreGraphics
import Foundation

nonisolated enum ConversationScrollAnchorMath {
  static func isPrependTransition(from oldRowIDs: [TimelineRowID], to newRowIDs: [TimelineRowID]) -> Bool {
    guard !oldRowIDs.isEmpty else { return false }
    guard newRowIDs.count > oldRowIDs.count else { return false }
    return newRowIDs.suffix(oldRowIDs.count).elementsEqual(oldRowIDs)
  }

  static func captureDelta(viewportTopY: CGFloat, rowTopY: CGFloat) -> Double {
    Double(viewportTopY - rowTopY)
  }

  static func restoredViewportTop(
    rowTopY: CGFloat,
    deltaFromRowTop: Double,
    contentHeight: CGFloat,
    viewportHeight: CGFloat
  ) -> CGFloat {
    let rawTargetY = rowTopY + CGFloat(deltaFromRowTop)
    let maxY = max(0, contentHeight - viewportHeight)
    return max(0, min(maxY, rawTargetY))
  }
}
