//
//  TimelineScrollAnchor.swift
//  OrbitDock
//
//  Bottom-pinning + position preservation on prepend.
//  Works with both NSTableView (macOS) and UICollectionView (iOS).
//

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

struct ScrollAnchorState {
  var isPinnedToBottom: Bool = true
  var firstVisibleRowID: String?
  var firstVisibleOffset: CGFloat = 0

  mutating func breakPin() {
    isPinnedToBottom = false
  }

  mutating func repin() {
    isPinnedToBottom = true
  }
}

#if os(macOS)
  enum TimelineScrollAnchor {
    /// Save the current first-visible row before a prepend operation.
    static func saveAnchor(
      scrollView: NSScrollView,
      tableView: NSTableView,
      entryIDs: [String]
    ) -> ScrollAnchorState {
      let clipView = scrollView.contentView
      let visibleRect = clipView.documentVisibleRect
      var state = ScrollAnchorState()

      // Check if pinned to bottom
      guard let documentView = scrollView.documentView else { return state }
      let maxY = max(0, documentView.bounds.height - clipView.bounds.height)
      state.isPinnedToBottom = clipView.bounds.origin.y >= max(0, maxY - 8)

      // Find first visible row
      let firstVisibleRow = tableView.rows(in: visibleRect).location
      if firstVisibleRow >= 0, firstVisibleRow < entryIDs.count {
        state.firstVisibleRowID = entryIDs[firstVisibleRow]
        let rowRect = tableView.rect(ofRow: firstVisibleRow)
        state.firstVisibleOffset = visibleRect.origin.y - rowRect.origin.y
      }

      return state
    }

    /// Restore scroll position after a prepend by finding the anchor row's new index.
    static func restoreAnchor(
      _ anchor: ScrollAnchorState,
      scrollView: NSScrollView,
      tableView: NSTableView,
      entryIDs: [String]
    ) {
      guard !anchor.isPinnedToBottom else {
        scrollToBottom(scrollView: scrollView)
        return
      }

      guard let anchorID = anchor.firstVisibleRowID,
            let newIndex = entryIDs.firstIndex(of: anchorID)
      else { return }

      let rowRect = tableView.rect(ofRow: newIndex)
      let targetY = rowRect.origin.y + anchor.firstVisibleOffset
      let clipView = scrollView.contentView
      clipView.scroll(to: NSPoint(x: 0, y: targetY))
      scrollView.reflectScrolledClipView(clipView)
    }

    static func scrollToBottom(scrollView: NSScrollView) {
      guard let documentView = scrollView.documentView else { return }
      let clipView = scrollView.contentView
      let maxY = max(0, documentView.bounds.height - clipView.bounds.height)
      clipView.scroll(to: NSPoint(x: 0, y: maxY))
      scrollView.reflectScrolledClipView(clipView)
    }
  }
#endif
