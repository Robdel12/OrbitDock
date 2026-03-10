#if os(macOS)

  import AppKit
  import os

  extension ConversationCollectionViewController {
    func numberOfRows(in tableView: NSTableView) -> Int {
      currentRows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
      AppKitConversationRowFactory.makeView(
        tableView: tableView,
        row: row,
        context: rowContext,
        handlers: rowHandlers,
        logger: logger
      )
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
      AppKitConversationRowFactory.makeRowView(
        tableView: tableView,
        row: row,
        context: rowContext
      )
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
      guard row >= 0, row < currentRows.count else { return 1 }
      let width = availableRowWidth
      let measurementWidth = width > 1
        ? width
        : max(lastKnownWidth, tableColumn.width, tableView.bounds.width, view.bounds.width)

      if measurementWidth <= 1 {
        return tableView.rowHeight
      }

      guard let cacheKey = heightCacheKey(forRow: row) else { return 1 }
      if let cachedHeight = heightEngine.height(for: cacheKey) {
        signposter.emitEvent("timeline-height-cache-hit")
        return cachedHeight
      }
      signposter.emitEvent("timeline-height-cache-miss")

      let measuredHeight = AppKitConversationRowFactory.height(
        for: row,
        context: rowContext,
        measurementWidth: measurementWidth
      )
      heightEngine.store(measuredHeight, for: cacheKey)
      return measuredHeight
    }
  }

#endif
