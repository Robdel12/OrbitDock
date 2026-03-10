//
//  ConversationHeightEngine.swift
//  OrbitDock
//
//  Deterministic row height cache keyed by row ID + width bucket + layout hash.
//

import CoreGraphics
import Foundation

nonisolated struct HeightCacheKey: Hashable, Sendable {
  let rowID: TimelineRowID
  let widthBucket: Int
  let layoutHash: Int
}

@MainActor
final class ConversationHeightEngine {
  private var heightsByKey: [HeightCacheKey: CGFloat] = [:]
  private var latestKeyByRowID: [TimelineRowID: HeightCacheKey] = [:]

  /// Row IDs that have already received one intrinsic-height correction.
  /// Once corrected, further corrections for the same cache key are rejected
  /// to prevent NSHostingView oscillation across cell recycles.
  private var correctedRowIDs: Set<TimelineRowID> = []

  func height(for key: HeightCacheKey) -> CGFloat? {
    heightsByKey[key]
  }

  func store(_ height: CGFloat, for key: HeightCacheKey) {
    if let previousKey = latestKeyByRowID[key.rowID], previousKey != key {
      heightsByKey[previousKey] = nil
      // Key changed → content changed → allow a fresh correction
      correctedRowIDs.remove(key.rowID)
    }
    heightsByKey[key] = height
    latestKeyByRowID[key.rowID] = key
  }

  /// Attempt to store a correction from a live cell's intrinsic height.
  /// Returns `true` if accepted, `false` if this row was already corrected
  /// for the same cache key (oscillation guard).
  @discardableResult
  func storeCorrection(_ height: CGFloat, for key: HeightCacheKey) -> Bool {
    if correctedRowIDs.contains(key.rowID),
       latestKeyByRowID[key.rowID] == key
    {
      return false
    }
    store(height, for: key)
    correctedRowIDs.insert(key.rowID)
    return true
  }

  func invalidate(rowID: TimelineRowID) {
    guard let key = latestKeyByRowID.removeValue(forKey: rowID) else { return }
    heightsByKey[key] = nil
    correctedRowIDs.remove(rowID)
  }

  func invalidate(rowIDs: some Sequence<TimelineRowID>) {
    for rowID in rowIDs {
      invalidate(rowID: rowID)
    }
  }

  func invalidateAll() {
    heightsByKey.removeAll(keepingCapacity: true)
    latestKeyByRowID.removeAll(keepingCapacity: true)
    correctedRowIDs.removeAll(keepingCapacity: true)
  }

  func prune(validRowIDs: Set<TimelineRowID>) {
    guard !latestKeyByRowID.isEmpty else { return }
    let stale = latestKeyByRowID.keys.filter { !validRowIDs.contains($0) }
    invalidate(rowIDs: stale)
  }
}
