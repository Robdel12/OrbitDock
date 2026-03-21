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
//  Initial positioning strategy:
//  - Use .defaultScrollAnchor(.bottom) for the first layout pass.
//  - Follow with a single non-animated scrollTo after the first yield when
//    the timeline is pinned, which avoids "blank until scroll" reveal races
//    without hiding the entire conversation behind an overlay.
//

import SwiftUI

struct TimelineScrollView: View {
  let viewModel: ConversationTimelineViewModel
  let sessionId: String
  let clients: ServerClients
  let onLoadMore: (() -> Void)?
  let isPinned: Bool
  let scrollToBottomTrigger: Int
  let onReachedBottom: () -> Void
  let onLeftBottomByUser: () -> Void

  @State private var sentinelVisible = true
  @State private var userIsLiveScrolling = false

  @State private var didPerformInitialScroll = false

  init(
    viewModel: ConversationTimelineViewModel,
    sessionId: String,
    clients: ServerClients,
    onLoadMore: (() -> Void)?,
    isPinned: Bool,
    scrollToBottomTrigger: Int,
    onReachedBottom: @escaping () -> Void,
    onLeftBottomByUser: @escaping () -> Void
  ) {
    self.viewModel = viewModel
    self.sessionId = sessionId
    self.clients = clients
    self.onLoadMore = onLoadMore
    self.isPinned = isPinned
    self.scrollToBottomTrigger = scrollToBottomTrigger
    self.onReachedBottom = onReachedBottom
    self.onLeftBottomByUser = onLeftBottomByUser
  }

  /// Lightweight value that changes when auto-scroll should fire.
  /// Captures entry count (new messages) and a coarse streaming bucket
  /// for the last message so we do not scroll on every single token.
  private var autoScrollVersion: Int {
    let displayedEntries = viewModel.displayedEntries
    var h = displayedEntries.count
    if let last = displayedEntries.last {
      h = h &* 31 &+ last.id.hashValue
      switch last.row {
        case let .assistant(msg) where msg.isStreaming:
          h = h &* 31 &+ streamingBucket(for: msg.content)
        case let .thinking(msg) where msg.isStreaming:
          h = h &* 31 &+ streamingBucket(for: msg.content)
        default: break
      }
    }
    return h
  }

  var body: some View {
    let displayed = viewModel.displayedEntries

    ScrollViewReader { proxy in
      ScrollView(.vertical) {
        LazyVStack(spacing: 0) {
          // Pagination sentinel — triggers history load when scrolled into view.
          // Identity changes when older messages prepend (first entry's sequence
          // changes), so onAppear fires again for the next page.
          Color.clear
            .frame(height: 1)
            .id("pagination-\(displayed.first?.sequence ?? 0)")
            .onAppear {
              guard didPerformInitialScroll, !isPinned else { return }
              onLoadMore?()
            }

          ForEach(displayed) { entry in
            TimelineRowHost(
              entry: entry,
              sessionId: sessionId,
              clients: clients,
              viewModel: viewModel
            )
            .id(entry.id)
          }

          // Bottom sentinel — tracks viewport visibility for pin state.
          // Also signals that the scroll view has settled at the bottom (isReady).
          Color.clear
            .frame(height: 1)
            .id("timeline-bottom")
            .onAppear {
              sentinelVisible = true
              guard !isPinned else { return }
              onReachedBottom()
            }
            .onDisappear {
              sentinelVisible = false
              guard isPinned, userIsLiveScrolling else { return }
              onLeftBottomByUser()
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
      .task {
        guard !didPerformInitialScroll else { return }
        didPerformInitialScroll = true
        await Task.yield()
        guard isPinned else { return }
        scrollToBottom(with: proxy)
      }
      .onChange(of: autoScrollVersion) { _, _ in
        guard isPinned else { return }
        scrollToBottom(with: proxy)
      }
      .onChange(of: scrollToBottomTrigger) { _, _ in
        scrollToBottom(with: proxy)
      }
      .onChange(of: userIsLiveScrolling) { _, isScrolling in
        guard !isScrolling, isPinned, !sentinelVisible else { return }
        onLeftBottomByUser()
      }
    }
  }

  private func scrollToBottom(with proxy: ScrollViewProxy) {
    var transaction = Transaction()
    transaction.animation = nil
    withTransaction(transaction) {
      proxy.scrollTo("timeline-bottom", anchor: .bottom)
    }
  }

  private func streamingBucket(for content: String) -> Int {
    content.count / 32
  }
}

private struct TimelineRowHost: View {
  let entry: ServerConversationRowEntry
  let sessionId: String
  let clients: ServerClients
  let viewModel: ConversationTimelineViewModel

  private var expandableId: String? {
    switch entry.row {
      case let .tool(toolRow):
        toolRow.id
      case let .activityGroup(group):
        group.id
      default:
        nil
    }
  }

  private var fetchId: String? {
    switch entry.row {
      case let .tool(toolRow):
        toolRow.id
      case let .activityGroup(group):
        group.id
      default:
        nil
    }
  }

  private var isExpanded: Bool {
    expandableId.map { viewModel.isExpanded($0) } ?? false
  }

  var body: some View {
    TimelineRowContent(
      entry: entry,
      isExpanded: isExpanded,
      sessionId: sessionId,
      clients: clients,
      fetchedContent: fetchId.flatMap { viewModel.content(for: $0) },
      isLoadingContent: fetchId.map { viewModel.isFetching($0) } ?? false,
      onToggle: toggle,
      isItemExpanded: viewModel.isExpanded(_:),
      contentForChild: viewModel.content(for:),
      isChildLoading: viewModel.isFetching(_:)
    )
    .task(id: isExpanded) {
      guard isExpanded, let fetchId else { return }
      viewModel.fetchContentIfNeeded(rowId: fetchId, sessionId: sessionId, clients: clients)
      if case let .activityGroup(group) = entry.row {
        for child in group.children where viewModel.isExpanded(child.id) {
          viewModel.fetchContentIfNeeded(rowId: child.id, sessionId: sessionId, clients: clients)
        }
      }
    }
  }

  private func toggle(_ id: String) {
    let nowExpanded = viewModel.toggleExpanded(id)
    if nowExpanded {
      viewModel.fetchContentIfNeeded(rowId: id, sessionId: sessionId, clients: clients)
    }
  }
}
