//
//  TimelineViewController.swift
//  OrbitDock
//
//  NSTableView (macOS) / UICollectionView (iOS) host for the conversation timeline.
//  Cell content is SwiftUI via NSHostingView/UIHostingConfiguration.
//  Expand/collapse is handled in SwiftUI via onToggle callbacks — shared across platforms.
//

import SwiftUI

// MARK: - SwiftUI Representable

#if os(macOS)
  import AppKit

  struct TimelineRepresentable: NSViewControllerRepresentable {
    let entries: [ServerConversationRowEntry]
    let revision: Int
    @Binding var isPinned: Bool
    let sessionId: String
    let clients: ServerClients
    var viewMode: ChatViewMode = .focused
    let onLoadMore: (() -> Void)?

    func makeNSViewController(context: Context) -> TimelineViewController {
      NSLog("🟢 TimelineRepresentable: makeNSViewController entries=%d", entries.count)
      let controller = TimelineViewController()
      controller.onLoadMore = onLoadMore
      controller.sessionId = sessionId
      controller.clients = clients
      controller.viewMode = viewMode
      controller.viewport.onPinnedStateChanged = { [self] pinned in
        self.isPinned = pinned
      }
      controller.apply(entries: entries, isPinned: isPinned)
      return controller
    }

    func updateNSViewController(_ controller: TimelineViewController, context: Context) {
      controller.onLoadMore = onLoadMore
      controller.sessionId = sessionId
      controller.clients = clients
      controller.viewMode = viewMode
      controller.viewport.onPinnedStateChanged = { [self] pinned in
        self.isPinned = pinned
      }
      controller.apply(entries: entries, isPinned: isPinned)
    }
  }

#else
  import UIKit

  struct TimelineRepresentable: UIViewControllerRepresentable {
    let entries: [ServerConversationRowEntry]
    let revision: Int
    @Binding var isPinned: Bool
    let sessionId: String
    let clients: ServerClients
    var viewMode: ChatViewMode = .focused
    let onLoadMore: (() -> Void)?

    func makeUIViewController(context: Context) -> TimelineCollectionViewController {
      let controller = TimelineCollectionViewController()
      controller.onLoadMore = onLoadMore
      controller.sessionId = sessionId
      controller.clients = clients
      controller.viewMode = viewMode
      controller.apply(entries: entries, isPinned: isPinned)
      return controller
    }

    func updateUIViewController(_ controller: TimelineCollectionViewController, context: Context) {
      controller.onLoadMore = onLoadMore
      controller.sessionId = sessionId
      controller.clients = clients
      controller.viewMode = viewMode
      controller.apply(entries: entries, isPinned: isPinned)
    }
  }
#endif

// MARK: - macOS: NSTableView Cell Container

#if os(macOS)

  /// Wraps NSHostingView with Auto Layout constraints that pin it to the column width.
  /// This prevents horizontal overflow (NSHostingView expanding beyond the column)
  /// while letting the content height drive the row height via `usesAutomaticRowHeights`.
  private final class TimelineCellView: NSView {
    private let hostingView: NSHostingView<TimelineRowContent>

    init(rootView: TimelineRowContent) {
      hostingView = NSHostingView(rootView: rootView)
      super.init(frame: .zero)

      // Only report intrinsic content size (for height). Remove .minSize so the
      // hosting view can be compressed to the column width for wide content.
      hostingView.sizingOptions = [.intrinsicContentSize]
      hostingView.translatesAutoresizingMaskIntoConstraints = false
      addSubview(hostingView)

      // Pin all four edges — width is forced by the column, height flows from content.
      NSLayoutConstraint.activate([
        hostingView.topAnchor.constraint(equalTo: topAnchor),
        hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
        hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
        hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
      ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var rootView: TimelineRowContent {
      get { hostingView.rootView }
      set { hostingView.rootView = newValue }
    }
  }

  // MARK: - macOS: NSTableView + TimelineCellView

  final class TimelineViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onLoadMore: (() -> Void)?
    var sessionId: String = ""
    var clients: ServerClients?
    var viewMode: ChatViewMode = .focused

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let tableColumn = NSTableColumn(identifier: .init("timeline"))

    let dataSource = TimelineDataSource()
    let rowState = TimelineRowStateStore()
    let viewport = TimelineViewportController()
    private var lastMeasuredWidth: CGFloat = 0

    override func loadView() {
      view = NSView()
      print("this even???")
      view.wantsLayer = true
      view.layer?.backgroundColor = NSColor(Color.backgroundPrimary).cgColor

      scrollView.translatesAutoresizingMaskIntoConstraints = false
      scrollView.drawsBackground = false
      scrollView.hasVerticalScroller = true
      scrollView.hasHorizontalScroller = false
      scrollView.horizontalScrollElasticity = .none
      scrollView.autohidesScrollers = true
      view.addSubview(scrollView)

      tableView.addTableColumn(tableColumn)
      tableView.headerView = nil
      tableView.backgroundColor = .clear
      tableView.intercellSpacing = .zero
      tableView.selectionHighlightStyle = .none
      tableView.focusRingType = .none
      tableView.allowsEmptySelection = true
      tableView.usesAutomaticRowHeights = false
      tableView.delegate = self
      tableView.dataSource = self
      scrollView.documentView = tableView

      NSLayoutConstraint.activate([
        scrollView.topAnchor.constraint(equalTo: view.topAnchor),
        scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      ])

      NotificationCenter.default.addObserver(
        self, selector: #selector(userDidScroll(_:)),
        name: NSScrollView.willStartLiveScrollNotification, object: scrollView
      )

      NSLog("🔧 TIMELINE INIT hasHScroller=\(scrollView.hasHorizontalScroller) hElasticity=\(scrollView.horizontalScrollElasticity.rawValue) autoRowH=\(tableView.usesAutomaticRowHeights)")
    }

    // MARK: - Data

    func apply(entries: [ServerConversationRowEntry], isPinned: Bool) {
      let entryIDs = entries.map(\.id)
      viewport.prepareForUpdate(
        scrollView: scrollView, tableView: tableView,
        entryIDs: entryIDs, externalPinned: isPinned
      )

      let diff = dataSource.apply(entries, viewMode: viewMode)

      if diff.isFullReload {
        tableView.reloadData()
      } else if !diff.updatedIndexes.isEmpty {
        // Invalidate height cache for changed rows
        for idx in diff.updatedIndexes {
          if let entry = dataSource.entry(at: idx) {
            rowState.invalidateHeight(entry.id)
          }
        }
        tableView.reloadData(forRowIndexes: diff.updatedIndexes, columnIndexes: IndexSet(integer: 0))
        invalidateHeights(diff.updatedIndexes)
      }

      updateColumnWidth()
      viewport.finalizeUpdate(
        scrollView: scrollView, tableView: tableView,
        entryIDs: dataSource.entries.map(\.id)
      )
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
      dataSource.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
      guard let entry = dataSource.entry(at: row) else { return nil }

      let reuseID = NSUserInterfaceItemIdentifier("HostingCell")
      let width = max(320, self.tableColumn.width)
      let rowIndex = row
      let content = makeRowContent(entry: entry, rowIndex: rowIndex, width: width)

      let cellView: TimelineCellView
      if let existing = tableView.makeView(withIdentifier: reuseID, owner: self) as? TimelineCellView {
        existing.rootView = content
        cellView = existing
      } else {
        cellView = TimelineCellView(rootView: content)
        cellView.identifier = reuseID
      }

      // DEBUG: Log after layout to detect width overflow
      DispatchQueue.main.async { [weak cellView, weak self] in
        guard let cellView, let self else { return }
        let cellWidth = cellView.frame.width
        let intrinsicWidth = cellView.fittingSize.width
        let colWidth = self.tableColumn.width
        if intrinsicWidth > colWidth + 1 {
          let rowType = Self.rowTypeName(entry.row)
          NSLog("⚠️ WIDTH OVERFLOW row=\(row) type=\(rowType) intrinsic=\(Int(intrinsicWidth)) col=\(Int(colWidth)) cell=\(Int(cellWidth))")
        }
      }

      return cellView
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
      false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
      guard let entry = dataSource.entry(at: row) else { return 44 }
      let rowId = entry.id
      let width = max(320, tableColumn.width)

      // Skip cache for streaming rows (content changes every push)
      let isStreaming: Bool
      switch entry.row {
      case let .assistant(msg): isStreaming = msg.isStreaming
      case let .thinking(msg): isStreaming = msg.isStreaming
      default: isStreaming = false
      }

      if !isStreaming, let cached = rowState.cachedHeight(rowId) {
        return cached
      }

      let height = TimelineRowMeasurement.height(for: entry, rowState: rowState, width: width)
      let rowType = Self.rowTypeName(entry.row)
      let prevCached = rowState.cachedHeight(rowId)
      if prevCached == nil || abs((prevCached ?? 0) - height) > 1 {
        NSLog("📏 HEIGHT row=\(row) type=\(rowType) h=\(Int(height)) w=\(Int(width)) streaming=\(isStreaming) prev=\(prevCached.map { Int($0) }.map(String.init) ?? "nil")")
      }

      if !isStreaming {
        rowState.cacheHeight(rowId, height)
      }
      return height
    }

    // MARK: - Layout

    override func viewDidLayout() {
      super.viewDidLayout()
      updateColumnWidth()
      let width = tableColumn.width
      guard abs(width - lastMeasuredWidth) > 1 else { return }
      lastMeasuredWidth = width
      guard dataSource.count > 0 else { return }
      rowState.invalidateAllHeights()
      invalidateHeights(IndexSet(integersIn: 0 ..< dataSource.count))
      viewport.handleWidthChange(scrollView: scrollView)
    }

    // MARK: - Scroll

    @objc private func userDidScroll(_ notification: Notification) {
      viewport.userDidScroll(scrollView: scrollView)
    }

    // MARK: - Helpers

    private func isRowExpanded(_ entry: ServerConversationRowEntry) -> Bool {
      switch entry.row {
      case let .tool(toolRow): rowState.isExpanded(toolRow.id)
      case let .thinking(msg): rowState.isExpanded(msg.id)
      case let .activityGroup(group): rowState.isExpanded(group.id)
      default: false
      }
    }

    private func makeRowContent(entry: ServerConversationRowEntry, rowIndex: Int, width: CGFloat) -> TimelineRowContent {
      let rowId = Self.rowId(for: entry)
      let expanded = isRowExpanded(entry)

      // Trigger fetch if expanded and content not yet cached
      let entryId = entry.id
      if expanded, let clients {
        if let rowId {
          rowState.fetchContentIfNeeded(rowId: rowId, sessionId: sessionId, clients: clients) { [weak self] in
            guard let self else { return }
            self.rowState.invalidateHeight(entryId)
            let indexes = IndexSet(integer: rowIndex)
            self.tableView.reloadData(forRowIndexes: indexes, columnIndexes: IndexSet(integer: 0))
            self.invalidateHeights(indexes)
          }
        }
        // For activity groups, also fetch expanded children
        if case let .activityGroup(group) = entry.row {
          for child in group.children where rowState.isExpanded(child.id) {
            rowState.fetchContentIfNeeded(rowId: child.id, sessionId: sessionId, clients: clients) { [weak self] in
              guard let self else { return }
              self.rowState.invalidateHeight(entryId)
              let indexes = IndexSet(integer: rowIndex)
              self.tableView.reloadData(forRowIndexes: indexes, columnIndexes: IndexSet(integer: 0))
              self.invalidateHeights(indexes)
            }
          }
        }
      }

      return TimelineRowContent(
        entry: entry, isExpanded: expanded, availableWidth: width,
        sessionId: sessionId, clients: clients,
        fetchedContent: rowId.flatMap { rowState.content(for: $0) },
        isLoadingContent: rowId.map { rowState.isFetching($0) } ?? false,
        onContentLoaded: { [weak self] in
          guard let self else { return }
          self.rowState.invalidateHeight(entryId)
          self.invalidateHeights(IndexSet(integer: rowIndex))
        },
        onToggle: { [weak self] id in
          guard let self else { return }
          self.rowState.toggleExpanded(id)
          self.rowState.invalidateHeight(entryId)
          let indexes = IndexSet(integer: rowIndex)
          self.tableView.reloadData(forRowIndexes: indexes, columnIndexes: IndexSet(integer: 0))
          self.invalidateHeights(indexes)
        },
        isItemExpanded: { [weak self] id in
          self?.rowState.isExpanded(id) ?? false
        },
        contentForChild: { [weak self] childId in
          self?.rowState.content(for: childId)
        },
        isChildLoading: { [weak self] childId in
          self?.rowState.isFetching(childId) ?? false
        },
        onCodeBlockToggle: { [weak self] in
          guard let self else { return }
          self.rowState.invalidateHeight(entryId)
          let indexes = IndexSet(integer: rowIndex)
          self.tableView.reloadData(forRowIndexes: indexes, columnIndexes: IndexSet(integer: 0))
          self.invalidateHeights(indexes)
        }
      )
    }

    private static func rowId(for entry: ServerConversationRowEntry) -> String? {
      switch entry.row {
      case let .tool(toolRow): toolRow.id
      case let .activityGroup(group): group.id
      default: nil
      }
    }

    /// Force layout to settle, then tell NSTableView that row heights changed.
    private func invalidateHeights(_ indexes: IndexSet) {
      tableView.layoutSubtreeIfNeeded()
      tableView.noteHeightOfRows(withIndexesChanged: indexes)
    }

    private func updateColumnWidth() {
      let targetWidth = max(320, scrollView.contentSize.width)
      guard abs(tableColumn.width - targetWidth) > 1 else { return }
      NSLog("📐 COL WIDTH \(Int(tableColumn.width)) -> \(Int(targetWidth)) scrollContent=\(Int(scrollView.contentSize.width)) viewBounds=\(Int(view.bounds.width))")
      tableColumn.width = targetWidth
    }

    private static func rowTypeName(_ row: ServerConversationRow) -> String {
      switch row {
      case .user: "user"
      case .assistant: "assistant"
      case .system: "system"
      case .thinking: "thinking"
      case .tool: "tool"
      case .activityGroup: "group"
      case .approval: "approval"
      case .question: "question"
      case .worker: "worker"
      case .plan: "plan"
      case .hook: "hook"
      case .handoff: "handoff"
      }
    }
  }

#else

  // MARK: - iOS: UICollectionView + UIHostingConfiguration Cells

  final class TimelineCollectionViewController: UIViewController, UICollectionViewDataSource,
    UICollectionViewDelegate
  {
    var onLoadMore: (() -> Void)?
    var sessionId: String = ""
    var clients: ServerClients?
    var viewMode: ChatViewMode = .focused

    private var collectionView: UICollectionView!
    let dataSource = TimelineDataSource()
    let rowState = TimelineRowStateStore()
    let viewport = TimelineViewportController()

    override func viewDidLoad() {
      super.viewDidLoad()
      view.backgroundColor = UIColor(Color.backgroundPrimary)

      let layout = UICollectionViewCompositionalLayout { _, _ in
        let itemSize = NSCollectionLayoutSize(
          widthDimension: .fractionalWidth(1.0),
          heightDimension: .estimated(44)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let groupSize = NSCollectionLayoutSize(
          widthDimension: .fractionalWidth(1.0),
          heightDimension: .estimated(44)
        )
        let group = NSCollectionLayoutGroup.vertical(layoutSize: groupSize, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 0
        return section
      }

      collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
      collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      collectionView.backgroundColor = .clear
      collectionView.dataSource = self
      collectionView.delegate = self
      collectionView.alwaysBounceVertical = true
      collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "HostingCell")
      view.addSubview(collectionView)
    }

    func apply(entries: [ServerConversationRowEntry], isPinned: Bool) {
      viewport.prepareForUpdate(externalPinned: isPinned)

      let diff = dataSource.apply(entries, viewMode: viewMode)

      if diff.isFullReload {
        collectionView.reloadData()
      } else if !diff.updatedIndexes.isEmpty {
        let indexPaths = diff.updatedIndexes.map { IndexPath(item: $0, section: 0) }
        collectionView.reloadItems(at: indexPaths)
      }

      viewport.finalizeUpdate(collectionView: collectionView, itemCount: dataSource.count)
    }

    // MARK: - UICollectionViewDataSource

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
      dataSource.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
      let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "HostingCell", for: indexPath)
      guard let entry = dataSource.entry(at: indexPath.item) else { return cell }

      let itemIndex = indexPath.item
      let rowId = Self.rowId(for: entry)
      let expanded = isRowExpanded(entry)

      // Trigger fetch if expanded and content not yet cached
      if expanded, let clients {
        if let rowId {
          rowState.fetchContentIfNeeded(rowId: rowId, sessionId: sessionId, clients: clients) { [weak self] in
            guard let self else { return }
            self.collectionView.reloadItems(at: [IndexPath(item: itemIndex, section: 0)])
          }
        }
        // For activity groups, also fetch expanded children
        if case let .activityGroup(group) = entry.row {
          for child in group.children where rowState.isExpanded(child.id) {
            rowState.fetchContentIfNeeded(rowId: child.id, sessionId: sessionId, clients: clients) { [weak self] in
              guard let self else { return }
              self.collectionView.reloadItems(at: [IndexPath(item: itemIndex, section: 0)])
            }
          }
        }
      }

      cell.contentConfiguration = UIHostingConfiguration {
        TimelineRowContent(
          entry: entry, isExpanded: expanded,
          availableWidth: collectionView.bounds.width,
          sessionId: sessionId, clients: clients,
          fetchedContent: rowId.flatMap { rowState.content(for: $0) },
          isLoadingContent: rowId.map { rowState.isFetching($0) } ?? false,
          onContentLoaded: { [weak self] in
            guard let self else { return }
            self.collectionView.reloadItems(at: [IndexPath(item: itemIndex, section: 0)])
          },
          onToggle: { [weak self] id in
            guard let self else { return }
            self.rowState.toggleExpanded(id)
            self.collectionView.reloadItems(at: [IndexPath(item: itemIndex, section: 0)])
          },
          isItemExpanded: { [weak self] id in
            self?.rowState.isExpanded(id) ?? false
          },
          contentForChild: { [weak self] childId in
            self?.rowState.content(for: childId)
          },
          isChildLoading: { [weak self] childId in
            self?.rowState.isFetching(childId) ?? false
          }
        )
      }
      .margins(.all, 0)

      return cell
    }

    // MARK: - Scroll

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
      viewport.userDidScroll(scrollView: scrollView)
    }

    // MARK: - Helpers

    private func isRowExpanded(_ entry: ServerConversationRowEntry) -> Bool {
      switch entry.row {
      case let .tool(toolRow): rowState.isExpanded(toolRow.id)
      case let .thinking(msg): rowState.isExpanded(msg.id)
      case let .activityGroup(group): rowState.isExpanded(group.id)
      default: false
      }
    }

    private static func rowId(for entry: ServerConversationRowEntry) -> String? {
      switch entry.row {
      case let .tool(toolRow): toolRow.id
      case let .activityGroup(group): group.id
      default: nil
      }
    }
  }
#endif
