#if os(macOS)
  import AppKit
  import SwiftUI

  final class MacTimelineHostViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onLoadMore: (() -> Void)?
    var onToggleToolExpansion: ((String) -> Void)?
    var onToggleActivityExpansion: ((String) -> Void)?
    var onFocusWorker: ((String) -> Void)?

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let tableColumn = NSTableColumn(identifier: .init("timeline"))

    private var viewState = MacTimelineViewState(rows: [], isPinnedToBottom: true, unreadCount: 0)
    private var rowControllers: [String: any MacTimelineRowController] = [:]
    private var orderedRowIDs: [String] = []
    private var lastMeasuredRowWidth: CGFloat = 0
    private var rowHeightOverrides: [String: CGFloat] = [:]

    override func loadView() {
      view = NSView()
      view.wantsLayer = true
      view.layer?.backgroundColor = NSColor(Color.backgroundPrimary).cgColor

      scrollView.translatesAutoresizingMaskIntoConstraints = false
      scrollView.drawsBackground = false
      scrollView.hasVerticalScroller = true
      scrollView.autohidesScrollers = true
      view.addSubview(scrollView)

      tableView.translatesAutoresizingMaskIntoConstraints = false
      tableView.addTableColumn(tableColumn)
      tableView.headerView = nil
      tableView.backgroundColor = .clear
      tableView.intercellSpacing = .zero
      tableView.selectionHighlightStyle = .none
      tableView.focusRingType = .none
      tableView.allowsEmptySelection = true
      tableView.delegate = self
      tableView.dataSource = self
      scrollView.documentView = tableView

      NSLayoutConstraint.activate([
        scrollView.topAnchor.constraint(equalTo: view.topAnchor),
        scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      ])
    }

    func apply(viewState: MacTimelineViewState) {
      let previousRows = self.viewState.rows
      let wasPinnedToBottom = self.viewState.isPinnedToBottom
      self.viewState = viewState
      rebuildControllers(from: viewState.rows)

      if previousRows.map(\.id) != viewState.rows.map(\.id) {
        orderedRowIDs = viewState.rows.map(\.id)
        tableView.reloadData()
        refreshDocumentGeometry(keepBottomPinned: viewState.isPinnedToBottom || wasPinnedToBottom)
        return
      }

      orderedRowIDs = viewState.rows.map(\.id)
      var rowsNeedingHeightInvalidation = IndexSet()
      var rowsNeedingReload = IndexSet()
      for (index, row) in viewState.rows.enumerated() where previousRows[index] != row {
        rowsNeedingHeightInvalidation.insert(index)
        let oldReuseIdentifier = reuseIdentifier(for: previousRows[index])
        let newReuseIdentifier = reuseIdentifier(for: row)
        if oldReuseIdentifier != newReuseIdentifier {
          rowsNeedingReload.insert(index)
          continue
        }
        if let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? NSTableCellView,
           let controller = rowControllers[row.id] {
          controller.configure(cell, availableWidth: availableRowWidth)
        } else {
          rowsNeedingReload.insert(index)
        }
      }
      if !rowsNeedingHeightInvalidation.isEmpty {
        // Batch height invalidation and row reloads together so NSTableView
        // recalculates the document height atomically. Without this, expanding
        // a tool row can leave the scroll view with a stale content size.
        NSAnimationContext.runAnimationGroup { ctx in
          ctx.duration = 0
          tableView.noteHeightOfRows(withIndexesChanged: rowsNeedingHeightInvalidation)
        }
        if !rowsNeedingReload.isEmpty {
          tableView.reloadData(forRowIndexes: rowsNeedingReload, columnIndexes: IndexSet(integer: 0))
        }
        refreshDocumentGeometry(keepBottomPinned: viewState.isPinnedToBottom || wasPinnedToBottom)
      } else if !rowsNeedingReload.isEmpty {
        tableView.reloadData(forRowIndexes: rowsNeedingReload, columnIndexes: IndexSet(integer: 0))
        refreshDocumentGeometry(keepBottomPinned: viewState.isPinnedToBottom || wasPinnedToBottom)
      }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
      orderedRowIDs.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
      guard row >= 0, row < orderedRowIDs.count,
            let controller = rowControllers[orderedRowIDs[row]] else { return 0 }
      if let override = rowHeightOverrides[orderedRowIDs[row]] {
        return override
      }
      return controller.height(for: availableRowWidth)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
      guard row >= 0, row < orderedRowIDs.count,
            let controller = rowControllers[orderedRowIDs[row]] else { return nil }

      let view = tableView.makeView(withIdentifier: controller.reuseIdentifier, owner: self) as? NSTableCellView
        ?? controller.makeView()
      view.identifier = controller.reuseIdentifier
      controller.configure(view, availableWidth: availableRowWidth)
      return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
      let row = tableView.selectedRow
      guard row >= 0 else { return }
      tableView.deselectRow(row)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
      false
    }

    override func viewDidLayout() {
      super.viewDidLayout()
      let width = availableRowWidth
      guard abs(width - lastMeasuredRowWidth) > 1 else { return }
      lastMeasuredRowWidth = width
      rowHeightOverrides.removeAll(keepingCapacity: true)
      guard !orderedRowIDs.isEmpty else { return }
      tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0 ..< orderedRowIDs.count))
      refreshDocumentGeometry(keepBottomPinned: viewState.isPinnedToBottom)
    }

    private func rebuildControllers(from rows: [MacTimelineRowRecord]) {
      var next: [String: any MacTimelineRowController] = [:]

      for row in rows {
        if let loadMore = rowControllers[row.id] as? MacTimelineLoadMoreRowController,
           loadMore.reuseIdentifier == reuseIdentifier(for: row)
        {
          loadMore.onLoadMore = onLoadMore
          loadMore.update(with: row)
          next[row.id] = loadMore
          continue
        }

        if let existing = rowControllers[row.id],
           existing.reuseIdentifier == reuseIdentifier(for: row)
        {
          existing.update(with: row)
          bindCallbacks(existing)
          next[row.id] = existing
        } else {
          let controller = MacTimelineRowControllerFactory.makeController(for: row)
          if let loadMore = controller as? MacTimelineLoadMoreRowController {
            loadMore.onLoadMore = onLoadMore
          }
          bindCallbacks(controller)
          next[row.id] = controller
        }
      }

      rowControllers = next
    }

    private func reuseIdentifier(for row: MacTimelineRowRecord) -> NSUserInterfaceItemIdentifier {
      switch row {
        case .utility:
          return NSUserInterfaceItemIdentifier("MacTimelineUtilityCellView")
        case .tool:
          return NSUserInterfaceItemIdentifier("MacTimelineToolCellView")
        case .expandedTool:
          return NativeExpandedToolCellView.reuseIdentifier
        case .loadMore:
          return NSUserInterfaceItemIdentifier("MacTimelineLoadMoreCellView")
        case .spacer:
          return NSUserInterfaceItemIdentifier("MacTimelineSpacerCellView")
        case .message:
          return NSUserInterfaceItemIdentifier("MacTimelineMessageCellView")
      }
    }

    private var availableRowWidth: CGFloat {
      max(320, tableColumn.width - (Spacing.lg * 2))
    }

    private func bindCallbacks(_ controller: any MacTimelineRowController) {
      if let tool = controller as? MacTimelineToolRowController {
        tool.onToggleExpansion = onToggleToolExpansion
      }
      if let utility = controller as? MacTimelineUtilityRowController {
        utility.onToggleExpansion = onToggleActivityExpansion
      }
      if let expandedTool = controller as? MacTimelineExpandedToolRowController {
        expandedTool.onToggleExpansion = onToggleToolExpansion
        expandedTool.onFocusWorker = onFocusWorker
        expandedTool.onMeasuredHeightChange = { [weak self] rowID, height in
          self?.applyMeasuredHeight(height, for: rowID)
        }
      }
    }

    private func applyMeasuredHeight(_ height: CGFloat, for rowID: String) {
      guard let rowIndex = orderedRowIDs.firstIndex(of: rowID) else { return }
      let current = rowHeightOverrides[rowID]
      guard current == nil || abs((current ?? 0) - height) > 1 else { return }
      let shouldKeepBottomPinned = isNearBottom || viewState.isPinnedToBottom
      rowHeightOverrides[rowID] = height
      let indexes = IndexSet(integer: rowIndex)
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0
        tableView.noteHeightOfRows(withIndexesChanged: indexes)
      }
      tableView.reloadData(forRowIndexes: indexes, columnIndexes: IndexSet(integer: 0))
      refreshDocumentGeometry(keepBottomPinned: shouldKeepBottomPinned)
    }

    private var isNearBottom: Bool {
      guard let documentView = scrollView.documentView else { return true }
      let clipView = scrollView.contentView
      let maxY = max(0, documentView.bounds.height - clipView.bounds.height)
      return clipView.bounds.origin.y >= max(0, maxY - 8)
    }

    private func refreshDocumentGeometry(keepBottomPinned: Bool) {
      reflowTableGeometry()
      scrollView.reflectScrolledClipView(scrollView.contentView)

      guard keepBottomPinned else { return }
      DispatchQueue.main.async { [weak self] in
        self?.scrollToBottom()
      }
    }

    private func updateColumnWidth() {
      let targetWidth = max(320, scrollView.contentSize.width)
      guard abs(tableColumn.width - targetWidth) > 1 else { return }
      tableColumn.width = targetWidth
    }

    private func reflowTableGeometry() {
      updateColumnWidth()
      tableView.layoutSubtreeIfNeeded()

      let contentHeight: CGFloat
      if tableView.numberOfRows > 0 {
        contentHeight = tableView.rect(ofRow: tableView.numberOfRows - 1).maxY
      } else {
        contentHeight = 0
      }

      let targetFrame = NSRect(
        x: 0,
        y: 0,
        width: tableColumn.width,
        height: contentHeight
      )
      if !tableView.frame.equalTo(targetFrame) {
        tableView.frame = targetFrame
      }

      tableView.layoutSubtreeIfNeeded()
      scrollView.documentView?.layoutSubtreeIfNeeded()
    }

    private func scrollToBottom() {
      guard let documentView = scrollView.documentView else { return }
      reflowTableGeometry()
      let clipView = scrollView.contentView
      let maxY = max(0, documentView.bounds.height - clipView.bounds.height)
      clipView.scroll(to: NSPoint(x: 0, y: maxY))
      scrollView.reflectScrolledClipView(clipView)
    }
  }
#endif
