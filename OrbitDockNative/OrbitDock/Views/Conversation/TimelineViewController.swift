//
//  TimelineViewController.swift
//  OrbitDock
//
//  NSTableView (macOS) / UICollectionView (iOS) host for the conversation timeline.
//  Cell content is SwiftUI via NSHostingView/UIHostingConfiguration.
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
      let controller = TimelineViewController()
      controller.onLoadMore = onLoadMore
      controller.sessionId = sessionId
      controller.clients = clients
      controller.viewMode = viewMode
      controller.onPinnedStateChanged = { [self] pinned in
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
      controller.onPinnedStateChanged = { [self] pinned in
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

// MARK: - macOS: NSTableView + NSHostingView Cells

#if os(macOS)
  final class TimelineViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onLoadMore: (() -> Void)?
    var onPinnedStateChanged: ((Bool) -> Void)?
    var sessionId: String = ""
    var clients: ServerClients?
    var viewMode: ChatViewMode = .focused

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let tableColumn = NSTableColumn(identifier: .init("timeline"))

    let dataSource = TimelineDataSource()
    private var expandedIDs: Set<String> = []
    private var expandedThinkingIDs: Set<String> = []
    private var expandedActivityIDs: Set<String> = []
    private var lastMeasuredWidth: CGFloat = 0
    private var isPinnedToBottom = true
    private var userHasScrolledAway = false

    // Measurement host — reused for height calculations
    private let measurementController = NSHostingController(
      rootView: TimelineRowContent(
        entry: ServerConversationRowEntry(
          sessionId: "", sequence: 0, turnId: nil,
          row: .system(ServerConversationMessageRow(
            id: "", content: "", turnId: nil, timestamp: nil, isStreaming: false, images: nil
          ))
        ),
        isExpanded: false
      )
    )

    override func loadView() {
      view = NSView()
      view.wantsLayer = true
      view.layer?.backgroundColor = NSColor(Color.backgroundPrimary).cgColor

      scrollView.translatesAutoresizingMaskIntoConstraints = false
      scrollView.drawsBackground = false
      scrollView.hasVerticalScroller = true
      scrollView.hasHorizontalScroller = false
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

      NotificationCenter.default.addObserver(
        self, selector: #selector(userDidScroll(_:)),
        name: NSScrollView.willStartLiveScrollNotification, object: scrollView
      )
    }

    // MARK: - Data

    func apply(entries: [ServerConversationRowEntry], isPinned: Bool) {
      if isPinned, !userHasScrolledAway {
        isPinnedToBottom = true
      }

      let diff = dataSource.apply(entries, viewMode: viewMode)

      if diff.isFullReload {
        tableView.reloadData()
        refreshGeometry(keepBottomPinned: isPinnedToBottom)
      } else if !diff.updatedIndexes.isEmpty {
        NSAnimationContext.runAnimationGroup { ctx in
          ctx.duration = 0
          tableView.noteHeightOfRows(withIndexesChanged: diff.updatedIndexes)
        }
        tableView.reloadData(forRowIndexes: diff.updatedIndexes, columnIndexes: IndexSet(integer: 0))
        refreshGeometry(keepBottomPinned: isPinnedToBottom)
      }
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
      dataSource.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
      guard let entry = dataSource.entry(at: row) else { return 0 }
      let width = max(320, tableColumn.width)
      let content = TimelineRowContent(entry: entry, isExpanded: isRowExpanded(entry), availableWidth: width, sessionId: sessionId, clients: clients)
      measurementController.rootView = content
      let measured = measurementController.sizeThatFits(in: CGSize(width: width, height: 10_000)).height
      // Guard against infinity/NaN from unconstrained SwiftUI layout
      if measured.isInfinite || measured.isNaN || measured > 10_000 {
        return 44
      }
      return max(1, min(measured, 10_000))
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
      guard let entry = dataSource.entry(at: row) else { return nil }

      let reuseID = NSUserInterfaceItemIdentifier("HostingCell")
      let width = max(320, self.tableColumn.width)
      let rowIndex = row
      let content = TimelineRowContent(
        entry: entry, isExpanded: isRowExpanded(entry), availableWidth: width,
        sessionId: sessionId, clients: clients,
        onContentLoaded: { [weak self] in
          guard let self else { return }
          // Invalidate height after async content loads
          let indexes = IndexSet(integer: rowIndex)
          NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            self.tableView.noteHeightOfRows(withIndexesChanged: indexes)
          }
          self.tableView.reloadData(forRowIndexes: indexes, columnIndexes: IndexSet(integer: 0))
        }
      )

      if let existing = tableView.makeView(withIdentifier: reuseID, owner: self) as? NSHostingView<TimelineRowContent> {
        existing.rootView = content
        return existing
      }

      let hostingView = NSHostingView(rootView: content)
      hostingView.identifier = reuseID
      return hostingView
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
      guard let entry = dataSource.entry(at: row) else { return false }
      // Defer toggle to avoid exclusive access violation — shouldSelectRow is on the
      // same call stack as heightOfRow, and both access expandedIDs.
      let rowIndex = row
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        switch entry.row {
        case let .tool(toolRow):
          self.toggleExpansion(toolRow.id, in: \.expandedIDs, row: rowIndex)
        case let .thinking(msg):
          self.toggleExpansion(msg.id, in: \.expandedThinkingIDs, row: rowIndex)
        case let .activityGroup(group):
          self.toggleExpansion(group.id, in: \.expandedActivityIDs, row: rowIndex)
        default:
          break
        }
      }
      return false
    }

    // MARK: - Layout

    override func viewDidLayout() {
      super.viewDidLayout()
      let width = tableColumn.width
      guard abs(width - lastMeasuredWidth) > 1 else { return }
      lastMeasuredWidth = width
      guard dataSource.count > 0 else { return }
      tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0 ..< dataSource.count))
      refreshGeometry(keepBottomPinned: isPinnedToBottom)
    }

    // MARK: - Scroll

    @objc private func userDidScroll(_ notification: Notification) {
      guard let documentView = scrollView.documentView else { return }
      let clipView = scrollView.contentView
      let maxY = max(0, documentView.bounds.height - clipView.bounds.height)
      let isAtBottom = clipView.bounds.origin.y >= max(0, maxY - 8)
      isPinnedToBottom = isAtBottom
      userHasScrolledAway = !isAtBottom
      onPinnedStateChanged?(isAtBottom)
    }

    // MARK: - Helpers

    private func isRowExpanded(_ entry: ServerConversationRowEntry) -> Bool {
      switch entry.row {
      case let .tool(toolRow): expandedIDs.contains(toolRow.id)
      case let .thinking(msg): expandedThinkingIDs.contains(msg.id)
      case let .activityGroup(group): expandedActivityIDs.contains(group.id)
      default: false
      }
    }

    private func toggleExpansion(_ id: String, in keyPath: ReferenceWritableKeyPath<TimelineViewController, Set<String>>, row: Int) {
      if self[keyPath: keyPath].contains(id) {
        self[keyPath: keyPath].remove(id)
      } else {
        self[keyPath: keyPath].insert(id)
      }
      let indexes = IndexSet(integer: row)
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0
        tableView.noteHeightOfRows(withIndexesChanged: indexes)
      }
      tableView.reloadData(forRowIndexes: indexes, columnIndexes: IndexSet(integer: 0))
    }

    private func refreshGeometry(keepBottomPinned: Bool) {
      updateColumnWidth()
      tableView.layoutSubtreeIfNeeded()

      let contentHeight: CGFloat = tableView.numberOfRows > 0
        ? tableView.rect(ofRow: tableView.numberOfRows - 1).maxY
        : 0

      let targetFrame = NSRect(x: 0, y: 0, width: tableColumn.width, height: contentHeight)
      if !tableView.frame.equalTo(targetFrame) {
        tableView.frame = targetFrame
      }

      tableView.layoutSubtreeIfNeeded()
      scrollView.documentView?.layoutSubtreeIfNeeded()
      scrollView.reflectScrolledClipView(scrollView.contentView)

      guard keepBottomPinned else { return }
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        TimelineScrollAnchor.scrollToBottom(scrollView: self.scrollView)
      }
    }

    private func updateColumnWidth() {
      let targetWidth = max(320, scrollView.contentSize.width)
      guard abs(tableColumn.width - targetWidth) > 1 else { return }
      tableColumn.width = targetWidth
    }
  }

#else

  // MARK: - iOS: UICollectionView + UIHostingConfiguration Cells

  final class TimelineCollectionViewController: UIViewController, UICollectionViewDataSource,
    UICollectionViewDelegateFlowLayout
  {
    var onLoadMore: (() -> Void)?
    var sessionId: String = ""
    var clients: ServerClients?
    var viewMode: ChatViewMode = .focused

    private var collectionView: UICollectionView!
    let dataSource = TimelineDataSource()
    private var expandedIDs: Set<String> = []
    private var expandedThinkingIDs: Set<String> = []
    private var expandedActivityIDs: Set<String> = []
    private var isPinnedToBottom = true

    private let measurementController = UIHostingController(
      rootView: TimelineRowContent(
        entry: ServerConversationRowEntry(
          sessionId: "", sequence: 0, turnId: nil,
          row: .system(ServerConversationMessageRow(
            id: "", content: "", turnId: nil, timestamp: nil, isStreaming: false, images: nil
          ))
        ),
        isExpanded: false
      )
    )

    override func viewDidLoad() {
      super.viewDidLoad()
      view.backgroundColor = UIColor(Color.backgroundPrimary)

      let layout = UICollectionViewFlowLayout()
      layout.scrollDirection = .vertical
      layout.minimumLineSpacing = 0
      layout.minimumInteritemSpacing = 0

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
      isPinnedToBottom = isPinned
      let diff = dataSource.apply(entries, viewMode: viewMode)

      if diff.isFullReload {
        collectionView.reloadData()
      } else if !diff.updatedIndexes.isEmpty {
        let indexPaths = diff.updatedIndexes.map { IndexPath(item: $0, section: 0) }
        collectionView.reloadItems(at: indexPaths)
      }

      if isPinned, dataSource.count > 0 {
        let lastIndex = IndexPath(item: dataSource.count - 1, section: 0)
        collectionView.scrollToItem(at: lastIndex, at: .bottom, animated: false)
      }
    }

    // MARK: - UICollectionViewDataSource

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
      dataSource.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
      let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "HostingCell", for: indexPath)
      guard let entry = dataSource.entry(at: indexPath.item) else { return cell }

      cell.contentConfiguration = UIHostingConfiguration {
        TimelineRowContent(entry: entry, isExpanded: isRowExpanded(entry), sessionId: sessionId, clients: clients)
      }
      .margins(.all, 0)

      return cell
    }

    // MARK: - UICollectionViewDelegateFlowLayout

    func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
      guard let entry = dataSource.entry(at: indexPath.item) else {
        return CGSize(width: collectionView.bounds.width, height: 0)
      }
      let width = collectionView.bounds.width
      let content = TimelineRowContent(entry: entry, isExpanded: isRowExpanded(entry), sessionId: sessionId, clients: clients)
      measurementController.rootView = content
      let size = measurementController.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
      return CGSize(width: width, height: size.height)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
      collectionView.deselectItem(at: indexPath, animated: false)
      guard let entry = dataSource.entry(at: indexPath.item) else { return }
      switch entry.row {
      case let .tool(toolRow):
        toggle(&expandedIDs, id: toolRow.id, at: indexPath)
      case let .thinking(msg):
        toggle(&expandedThinkingIDs, id: msg.id, at: indexPath)
      case let .activityGroup(group):
        toggle(&expandedActivityIDs, id: group.id, at: indexPath)
      default:
        break
      }
    }

    // MARK: - Scroll

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
      let maxOffset = scrollView.contentSize.height - scrollView.bounds.height
      isPinnedToBottom = scrollView.contentOffset.y >= max(0, maxOffset - 8)
    }

    // MARK: - Helpers

    private func isRowExpanded(_ entry: ServerConversationRowEntry) -> Bool {
      switch entry.row {
      case let .tool(toolRow): expandedIDs.contains(toolRow.id)
      case let .thinking(msg): expandedThinkingIDs.contains(msg.id)
      case let .activityGroup(group): expandedActivityIDs.contains(group.id)
      default: false
      }
    }

    private func toggle(_ set: inout Set<String>, id: String, at indexPath: IndexPath) {
      if set.contains(id) { set.remove(id) } else { set.insert(id) }
      collectionView.reloadItems(at: [indexPath])
    }
  }
#endif
