//
//  TimelineViewportController.swift
//  OrbitDock
//
//  Single owner for all scroll behavior: bottom-pinning, anchor preservation,
//  width-change relayout, and scroll-to-message.
//  Replaces scattered logic in TimelineScrollAnchor + TimelineViewController.
//

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

@MainActor
final class TimelineViewportController {
  private(set) var isPinnedToBottom: Bool = true
  var onPinnedStateChanged: ((Bool) -> Void)?

  /// Whether the user has actively scrolled away from bottom.
  /// Prevents re-pinning on data updates until the user scrolls back.
  private var userHasScrolledAway = false

  // Saved anchor for position preservation across data updates.
  private var savedAnchorRowID: String?
  private var savedAnchorOffset: CGFloat = 0

  // MARK: - User Scroll Detection

  #if os(macOS)
    /// Called from NSScrollView.willStartLiveScrollNotification.
    /// Only fires for user-initiated scroll (trackpad/mouse), not programmatic.
    func userDidScroll(scrollView: NSScrollView) {
      let isAtBottom = isScrolledToBottom(scrollView: scrollView)
      isPinnedToBottom = isAtBottom
      userHasScrolledAway = !isAtBottom
      onPinnedStateChanged?(isAtBottom)
    }
  #else
    /// Called from scrollViewDidScroll on iOS.
    func userDidScroll(scrollView: UIScrollView) {
      let maxOffset = scrollView.contentSize.height - scrollView.bounds.height
      let isAtBottom = scrollView.contentOffset.y >= max(0, maxOffset - 8)
      isPinnedToBottom = isAtBottom
      onPinnedStateChanged?(isAtBottom)
    }
  #endif

  // MARK: - Data Update Lifecycle

  #if os(macOS)
    /// Call before applying new data. Saves the current scroll anchor if not pinned.
    func prepareForUpdate(
      scrollView: NSScrollView,
      tableView: NSTableView,
      entryIDs: [String],
      externalPinned: Bool
    ) {
      if externalPinned, !userHasScrolledAway {
        isPinnedToBottom = true
      }

      guard !isPinnedToBottom else {
        savedAnchorRowID = nil
        return
      }

      // Save first visible row for anchor restoration
      let clipView = scrollView.contentView
      let visibleRect = clipView.documentVisibleRect
      let firstVisibleRow = tableView.rows(in: visibleRect).location
      if firstVisibleRow >= 0, firstVisibleRow < entryIDs.count {
        savedAnchorRowID = entryIDs[firstVisibleRow]
        let rowRect = tableView.rect(ofRow: firstVisibleRow)
        savedAnchorOffset = visibleRect.origin.y - rowRect.origin.y
      }
    }

    /// Call after data update + height invalidation. Restores anchor or pins to bottom.
    func finalizeUpdate(
      scrollView: NSScrollView,
      tableView: NSTableView,
      entryIDs: [String]
    ) {
      scrollView.documentView?.layoutSubtreeIfNeeded()

      if isPinnedToBottom {
        scrollToBottom(scrollView: scrollView)
        return
      }

      // Restore anchor position
      guard let anchorID = savedAnchorRowID,
            let newIndex = entryIDs.firstIndex(of: anchorID)
      else { return }

      let rowRect = tableView.rect(ofRow: newIndex)
      let targetY = rowRect.origin.y + savedAnchorOffset
      let clipView = scrollView.contentView
      clipView.scroll(to: NSPoint(x: 0, y: targetY))
      scrollView.reflectScrolledClipView(clipView)
      savedAnchorRowID = nil
    }

    /// Call after width change — save anchor, invalidate, restore.
    func handleWidthChange(scrollView: NSScrollView) {
      if isPinnedToBottom {
        scrollToBottom(scrollView: scrollView)
      }
    }

    func scrollToBottom(scrollView: NSScrollView) {
      guard let documentView = scrollView.documentView else { return }
      let clipView = scrollView.contentView
      let maxY = max(0, documentView.bounds.height - clipView.bounds.height)
      clipView.scroll(to: NSPoint(x: 0, y: maxY))
      scrollView.reflectScrolledClipView(clipView)
    }

    func scrollToMessage(id: String, in tableView: NSTableView, scrollView: NSScrollView, entryIDs: [String]) {
      guard let index = entryIDs.firstIndex(of: id) else { return }
      let rowRect = tableView.rect(ofRow: index)
      let clipView = scrollView.contentView
      clipView.scroll(to: NSPoint(x: 0, y: rowRect.origin.y))
      scrollView.reflectScrolledClipView(clipView)
      isPinnedToBottom = false
      userHasScrolledAway = true
      onPinnedStateChanged?(false)
    }

  #else

    /// Call before applying new data on iOS.
    func prepareForUpdate(externalPinned: Bool) {
      isPinnedToBottom = externalPinned
    }

    /// Call after data update on iOS. Scrolls to bottom if pinned.
    func finalizeUpdate(collectionView: UICollectionView, itemCount: Int) {
      guard isPinnedToBottom, itemCount > 0 else { return }
      let lastIndex = IndexPath(item: itemCount - 1, section: 0)
      collectionView.scrollToItem(at: lastIndex, at: .bottom, animated: false)
    }

  #endif

  // MARK: - Helpers

  #if os(macOS)
    private func isScrolledToBottom(scrollView: NSScrollView) -> Bool {
      guard let documentView = scrollView.documentView else { return true }
      let clipView = scrollView.contentView
      let maxY = max(0, documentView.bounds.height - clipView.bounds.height)
      return clipView.bounds.origin.y >= max(0, maxY - 8)
    }
  #endif
}
