//
//  TimelineScrollView.swift
//  OrbitDock
//
//  Pure SwiftUI replacement for NSTableView/UICollectionView timeline.
//  Heights are automatic — no manual measurement or caching needed.
//  Scroll position is managed via .scrollPosition(id:) binding.
//

import SwiftUI

struct TimelineScrollView: View {
  let entries: [ServerConversationRowEntry]
  let sessionId: String
  let clients: ServerClients
  var viewMode: ChatViewMode = .focused
  let onLoadMore: (() -> Void)?
  @Binding var isPinned: Bool

  @State private var rowState = TimelineRowStateStore()
  @State private var scrollPosition: String?
  @State private var isPinnedToBottom = true
  @State private var lastAppliedIDs: [String] = []

  /// Tool grouping happens here — computed fresh when entries change.
  private var displayEntries: [ServerConversationRowEntry] {
    if viewMode == .focused {
      return TimelineDataSource.groupToolRuns(entries)
    }
    return entries
  }

  var body: some View {
    let displayed = displayEntries

    GeometryReader { geometry in
      ScrollView(.vertical) {
        LazyVStack(spacing: 0) {
          // Pagination sentinel — triggers history load when scrolled into view
          Color.clear
            .frame(height: 1)
            .onAppear { onLoadMore?() }

          ForEach(displayed) { entry in
            timelineRow(entry, width: geometry.size.width)
              .id(entry.id)
          }

        }
        .scrollTargetLayout()
      }
      .scrollDismissesKeyboard(.interactively)
      .defaultScrollAnchor(.bottom)
      .scrollPosition(id: $scrollPosition, anchor: .bottom)
      .onChange(of: scrollPosition) { _, newPosition in
        handleScrollPositionChange(newPosition, lastID: displayed.last?.id)
      }
    }
    .background(Color.backgroundPrimary)
    .onChange(of: displayed.map(\.id)) { _, newIDs in
      handleEntriesChanged(newIDs: newIDs)
    }
  }

  // MARK: - Row Rendering

  @ViewBuilder
  private func timelineRow(_ entry: ServerConversationRowEntry, width: CGFloat) -> some View {
    let expandableId = Self.expandableId(for: entry)
    let isExpanded = expandableId.map { rowState.isExpanded($0) } ?? false
    let fetchId = Self.fetchableId(for: entry)

    TimelineRowContent(
      entry: entry,
      isExpanded: isExpanded,
      availableWidth: width,
      sessionId: sessionId,
      clients: clients,
      fetchedContent: fetchId.flatMap { rowState.content(for: $0) },
      isLoadingContent: fetchId.map { rowState.isFetching($0) } ?? false,
      onToggle: { id in
        let nowExpanded = rowState.toggleExpanded(id)
        // Fetch content for newly expanded children (activity group child tools)
        if nowExpanded {
          rowState.fetchContentIfNeeded(rowId: id, sessionId: sessionId, clients: clients)
        }
      },
      isItemExpanded: { id in
        rowState.isExpanded(id)
      },
      contentForChild: { id in
        rowState.content(for: id)
      },
      isChildLoading: { id in
        rowState.isFetching(id)
      }
    )
    .task(id: isExpanded) {
      guard isExpanded, let fetchId else { return }
      rowState.fetchContentIfNeeded(rowId: fetchId, sessionId: sessionId, clients: clients)
      // For activity groups, also fetch expanded children
      if case let .activityGroup(group) = entry.row {
        for child in group.children where rowState.isExpanded(child.id) {
          rowState.fetchContentIfNeeded(rowId: child.id, sessionId: sessionId, clients: clients)
        }
      }
    }
  }

  // MARK: - Scroll Behavior

  private func handleScrollPositionChange(_ newPosition: String?, lastID: String?) {
    let atBottom = newPosition == nil || newPosition == lastID
    isPinnedToBottom = atBottom
    isPinned = atBottom
  }

  private func handleEntriesChanged(newIDs: [String]) {
    guard newIDs != lastAppliedIDs else { return }
    let wasPinned = isPinnedToBottom
    lastAppliedIDs = newIDs

    if wasPinned, let lastID = newIDs.last {
      scrollPosition = lastID
    }
  }

  // MARK: - Row Identity Helpers

  /// Returns the ID used for expand/collapse state, if the row type supports it.
  private static func expandableId(for entry: ServerConversationRowEntry) -> String? {
    switch entry.row {
    case let .tool(toolRow): toolRow.id
    case let .thinking(msg): msg.id
    case let .activityGroup(group): group.id
    default: nil
    }
  }

  /// Returns the ID used for fetching expanded content, if applicable.
  private static func fetchableId(for entry: ServerConversationRowEntry) -> String? {
    switch entry.row {
    case let .tool(toolRow): toolRow.id
    case let .activityGroup(group): group.id
    default: nil
    }
  }
}
