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
//  Scroll-to-bottom strategy (two-phase reveal):
//  1. Timeline renders with .defaultScrollAnchor(.bottom) but is hidden behind
//     an opaque overlay so the user never sees a half-scrolled state.
//  2. When the bottom sentinel's onAppear fires (meaning the viewport is at
//     the bottom), the overlay fades out to reveal the settled timeline.
//  3. Fallback: if the sentinel doesn't appear after layout yields, a forced
//     scrollTo + reveal ensures the timeline is never stuck hidden.
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

  /// False until the scroll view has settled at the bottom. Content is hidden
  /// behind an opaque overlay until this flips to true.
  @State private var isReady = false

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
          // Pagination sentinel — triggers history load when scrolled into view.
          // Identity changes when older messages prepend (first entry's sequence
          // changes), so onAppear fires again for the next page.
          Color.clear
            .frame(height: 1)
            .id("pagination-\(entries.first?.sequence ?? 0)")
            .onAppear { onLoadMore?() }

          ForEach(displayed) { entry in
            timelineRow(entry)
              .id(entry.id)
          }

          // Bottom sentinel — tracks viewport visibility for pin state.
          // Also signals that the scroll view has settled at the bottom (isReady).
          Color.clear
            .frame(height: 1)
            .id("timeline-bottom")
            .onAppear {
              sentinelVisible = true
              if !isReady {
                withAnimation(Motion.fade) { isReady = true }
              }
              guard !isPinned else { return }
              isPinned = true
            }
            .onDisappear {
              sentinelVisible = false
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
      // Hide content until scroll position has settled at the bottom.
      .overlay {
        if !isReady {
          Color.backgroundPrimary
        }
      }
      .animation(Motion.fade, value: isReady)
      // Fallback: if defaultScrollAnchor didn't reach the bottom, force scroll + reveal.
      .task {
        await Task.yield()
        await Task.yield()
        guard !isReady else { return }
        proxy.scrollTo("timeline-bottom", anchor: .bottom)
        await Task.yield()
        withAnimation(Motion.fade) { isReady = true }
      }
      .onChange(of: autoScrollVersion) { _, _ in
        guard isPinned else { return }
        proxy.scrollTo("timeline-bottom", anchor: .bottom)
      }
      .onChange(of: scrollToBottomTrigger) { _, _ in
        proxy.scrollTo("timeline-bottom", anchor: .bottom)
      }
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
      if case let .activityGroup(group) = entry.row {
        for child in group.children where rowState.isExpanded(child.id) {
          rowState.fetchContentIfNeeded(rowId: child.id, sessionId: sessionId, clients: clients)
        }
      }
    }
  }

  // MARK: - Row Identity Helpers

  private static func expandableId(for entry: ServerConversationRowEntry) -> String? {
    switch entry.row {
      case let .tool(toolRow): toolRow.id
      case let .activityGroup(group): group.id
      default: nil
    }
  }

  private static func fetchableId(for entry: ServerConversationRowEntry) -> String? {
    switch entry.row {
      case let .tool(toolRow): toolRow.id
      case let .activityGroup(group): group.id
      default: nil
    }
  }
}
