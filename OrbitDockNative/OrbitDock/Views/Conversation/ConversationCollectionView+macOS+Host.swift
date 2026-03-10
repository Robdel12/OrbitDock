#if os(macOS)

  import AppKit

  extension ConversationCollectionViewController {
    override func viewDidLoad() {
      super.viewDidLoad()
      setupScrollView()
      setupTableView()
      setupScrollObservers()
      rebuildSnapshot(animated: false)
    }

    override func viewDidLayout() {
      super.viewDidLayout()
      updateTableColumnWidth()
      clampHorizontalOffsetIfNeeded()

      let width = availableRowWidth
      if abs(width - lastKnownWidth) > 0.5 {
        lastKnownWidth = width
        ConversationTimelineReducer.reduce(source: &sourceState, ui: &uiState, action: .widthChanged(width))
        heightEngine.invalidateAll()
        if !currentRows.isEmpty {
          tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0 ..< currentRows.count))
        }
      }

      if needsInitialScroll, !sourceState.messages.isEmpty {
        needsInitialScroll = false
        scrollToBottom(animated: false)
      }
    }

    var availableRowWidth: CGFloat {
      max(1, scrollView?.contentView.bounds.width ?? view.bounds.width)
    }

    private func setupScrollView() {
      scrollView = NSScrollView()
      scrollView.translatesAutoresizingMaskIntoConstraints = false
      scrollView.hasVerticalScroller = true
      scrollView.hasHorizontalScroller = false
      scrollView.horizontalScrollElasticity = .none
      scrollView.autohidesScrollers = true
      scrollView.drawsBackground = true
      scrollView.backgroundColor = ConversationLayout.backgroundPrimary
      scrollView.scrollerStyle = .overlay

      let clipView = VerticalOnlyClipView()
      clipView.postsBoundsChangedNotifications = true
      clipView.drawsBackground = true
      clipView.backgroundColor = ConversationLayout.backgroundPrimary
      scrollView.contentView = clipView

      view.addSubview(scrollView)
      NSLayoutConstraint.activate([
        // 1pt top margin works around a macOS Tahoe clipping regression where rows
        // bleed into the header area when the scroll view spans the full parent height.
        scrollView.topAnchor.constraint(equalTo: view.topAnchor, constant: 1),
        scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      ])
    }

    private func setupTableView() {
      UserDefaults.standard.set(false, forKey: "NSTableViewCanEstimateRowHeights")

      tableView = WidthClampedTableView(frame: .zero)
      tableView.delegate = self
      tableView.dataSource = self
      tableView.headerView = nil
      tableView.backgroundColor = ConversationLayout.backgroundPrimary
      tableView.usesAlternatingRowBackgroundColors = false
      tableView.selectionHighlightStyle = .none
      tableView.intercellSpacing = .zero
      tableView.gridStyleMask = []
      tableView.focusRingType = .none
      tableView.clipsToBounds = true
      // .plain removes the default cell-view insets that .automatic/.inset adds.
      // Without this, NSTableView offsets cells by ~16pt from the row's leading edge,
      // pushing content past the right boundary.
      tableView.style = .plain
      tableView.allowsColumnResizing = false
      tableView.allowsColumnReordering = false
      tableView.allowsColumnSelection = false
      tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
      tableView.rowHeight = 44

      tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("conversation-main-column"))
      tableColumn.isEditable = false
      tableColumn.resizingMask = .autoresizingMask
      tableColumn.minWidth = 1
      tableView.addTableColumn(tableColumn)

      tableView.frame = scrollView.bounds
      tableView.autoresizingMask = [.width]
      scrollView.documentView = tableView
      updateTableColumnWidth()
    }

    private func updateTableColumnWidth() {
      let width = availableRowWidth
      if abs(tableColumn.width - width) > 0.5 {
        tableColumn.width = width
      }
    }
  }

#endif
