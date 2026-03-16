//
//  TimelineScrollView.swift
//  OrbitDock
//
//  Pure SwiftUI replacement for NSTableView/UICollectionView timeline.
//  Heights are automatic — no manual measurement or caching needed.
//
//  Follow (pin-to-bottom) logic:
//  - Sentinel onAppear re-pins when user scrolls back to the bottom.
//  - Sentinel onDisappear marks the sentinel as off-screen but does NOT
//    immediately unpin — content growth also pushes the sentinel off-screen
//    before auto-scroll corrects it.
//  - Unpin only happens when a USER-INITIATED scroll ends with the sentinel
//    still off-screen. User scroll is detected via platform scroll-view
//    notifications (macOS) or pan gesture tracking (iOS) through
//    TimelineUserScrollDetector.
//

import SwiftUI

struct TimelineScrollView: View {
  let entries: [ServerConversationRowEntry]
  let sessionId: String
  let clients: ServerClients
  var viewMode: ChatViewMode = .focused
  let onLoadMore: (() -> Void)?
  @Binding var isPinned: Bool
  @Binding var scrollToBottomTrigger: Int

  @State private var rowState = TimelineRowStateStore()
  @State private var sentinelVisible = true
  @State private var userIsLiveScrolling = false

  /// Tool grouping happens here — computed fresh when entries change.
  private var displayEntries: [ServerConversationRowEntry] {
    if viewMode == .focused {
      return TimelineDataSource.groupToolRuns(entries)
    }
    return entries
  }

  /// Lightweight value that changes when auto-scroll should fire.
  /// Captures entry count (new messages) and last message content
  /// length (streaming growth) — O(1) to compute.
  private var autoScrollVersion: Int {
    var h = entries.count
    if let last = entries.last {
      switch last.row {
        case let .assistant(msg): h = h &* 31 &+ msg.content.count
        case let .thinking(msg): h = h &* 31 &+ msg.content.count
        default: break
      }
    }
    return h
  }

  var body: some View {
    let displayed = displayEntries

    ScrollViewReader { proxy in
      ScrollView(.vertical) {
        LazyVStack(spacing: 0) {
          // Pagination sentinel — triggers history load when scrolled into view
          Color.clear
            .frame(height: 1)
            .onAppear { onLoadMore?() }

          ForEach(displayed) { entry in
            timelineRow(entry)
              .id(entry.id)
          }

          // Bottom sentinel — tracks viewport visibility for pin state.
          // onAppear re-pins (user scrolled back to bottom).
          // onDisappear records that the sentinel left but does NOT unpin —
          // unpin is deferred to TimelineUserScrollDetector.
          Color.clear
            .frame(height: 1)
            .id("timeline-bottom")
            .onAppear {
              sentinelVisible = true
              guard !isPinned else { return }
              isPinned = true
            }
            .onDisappear {
              sentinelVisible = false
              // Unpin immediately only if the user is actively scrolling.
              // Content-push disappearances are corrected by auto-scroll.
              guard isPinned, userIsLiveScrolling else { return }
              isPinned = false
            }
        }
        .background {
          TimelineUserScrollDetector(isUserScrolling: $userIsLiveScrolling)
            .frame(width: 0, height: 0)
        }
      }
      .scrollDismissesKeyboard(.interactively)
      .defaultScrollAnchor(.bottom)
      .background(Color.backgroundPrimary)
      .onAppear {
        guard let lastID = displayed.last?.id else { return }
        proxy.scrollTo(lastID, anchor: .bottom)
      }
      .onChange(of: autoScrollVersion) { _, _ in
        guard isPinned, let lastID = displayed.last?.id else { return }
        proxy.scrollTo(lastID, anchor: .bottom)
      }
      .onChange(of: scrollToBottomTrigger) { _, _ in
        guard let lastID = displayed.last?.id else { return }
        proxy.scrollTo(lastID, anchor: .bottom)
      }
      // When user scroll ends, check if sentinel is still off-screen → unpin.
      // Handles momentum scrolling: macOS didEndLiveScrollNotification fires
      // after momentum settles; iOS tracks deceleration via contentOffset KVO.
      .onChange(of: userIsLiveScrolling) { _, isScrolling in
        guard !isScrolling, isPinned, !sentinelVisible else { return }
        isPinned = false
      }
    }
  }

  // MARK: - Row Rendering

  @ViewBuilder
  private func timelineRow(_ entry: ServerConversationRowEntry) -> some View {
    let expandableId = Self.expandableId(for: entry)
    let isExpanded = expandableId.map { rowState.isExpanded($0) } ?? false
    let fetchId = Self.fetchableId(for: entry)

    TimelineRowContent(
      entry: entry,
      isExpanded: isExpanded,
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
