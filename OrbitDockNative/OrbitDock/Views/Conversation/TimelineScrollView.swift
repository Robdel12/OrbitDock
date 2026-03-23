//
//  TimelineScrollView.swift
//  OrbitDock
//
//  Pure SwiftUI replacement for NSTableView/UICollectionView timeline.
//  Heights are automatic — no manual measurement or caching needed.
//
//  Follow (pin-to-bottom) logic:
//  - The timeline owns a bound scroll position anchored to the bottom sentinel.
//  - When pinned, the bound position stays on the bottom sentinel so container
//    height and content height changes preserve bottom alignment declaratively.
//  - User-driven scrolling is detected from SwiftUI scroll phase changes. We
//    only unpin after a user scroll settles away from the bottom.
//

import SwiftUI

struct TimelineScrollView: View {
  let viewModel: ConversationTimelineViewModel
  let sessionId: String
  let clients: ServerClients
  let onLoadMore: (() -> Void)?
  let isPinned: Bool
  let onReachedBottom: () -> Void
  let onLeftBottomByUser: () -> Void

  private static let bottomSentinelID = "timeline-bottom"

  @State private var bottomSentinelVisible = true
  @State private var scrollPositionID: String? = bottomSentinelID
  @State private var userDrivenScrollInFlight = false
  @State private var hasInitializedScrollPosition = false


  init(
    viewModel: ConversationTimelineViewModel,
    sessionId: String,
    clients: ServerClients,
    onLoadMore: (() -> Void)?,
    isPinned: Bool,
    onReachedBottom: @escaping () -> Void,
    onLeftBottomByUser: @escaping () -> Void
  ) {
    self.viewModel = viewModel
    self.sessionId = sessionId
    self.clients = clients
    self.onLoadMore = onLoadMore
    self.isPinned = isPinned
    self.onReachedBottom = onReachedBottom
    self.onLeftBottomByUser = onLeftBottomByUser
  }

  var body: some View {
    let displayed = viewModel.displayedEntries

    ScrollView(.vertical) {
      LazyVStack(spacing: 0) {
        // Pagination sentinel — triggers history load when scrolled into view.
        // Identity changes when older messages prepend (first entry's sequence
        // changes), so onAppear fires again for the next page.
        Color.clear
          .frame(height: 1)
          .id("pagination-\(displayed.first?.sequence ?? 0)")
          .onAppear {
            guard hasInitializedScrollPosition, !isPinned else { return }
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

        // Bottom sentinel — the declarative pinned target and visibility probe.
        Color.clear
          .frame(height: 1)
          .id(Self.bottomSentinelID)
          .onScrollVisibilityChange(threshold: 0.001) { isVisible in
            bottomSentinelVisible = isVisible
            guard isVisible, !isPinned else { return }
            onReachedBottom()
          }
      }
      .scrollTargetLayout()
    }
    .scrollDismissesKeyboard(.interactively)
    .defaultScrollAnchor(.bottom)
    .scrollPosition(id: $scrollPositionID, anchor: .bottom)
    .background(Color.backgroundPrimary)
    .task {
      guard !hasInitializedScrollPosition else { return }
      hasInitializedScrollPosition = true
      if isPinned {
        setPinnedScrollPosition()
      }
    }
    .onChange(of: isPinned) { _, pinned in
      guard pinned else { return }
      setPinnedScrollPosition()
    }
    .onScrollPhaseChange { _, newPhase in
      if isUserDrivenScrollPhase(newPhase) {
        userDrivenScrollInFlight = true
        return
      }

      if newPhase == .animating {
        userDrivenScrollInFlight = false
        return
      }

      guard newPhase == .idle else { return }
      defer { userDrivenScrollInFlight = false }

      guard userDrivenScrollInFlight else { return }
      guard isPinned, !bottomSentinelVisible else { return }
      onLeftBottomByUser()
    }
  }

  private func setPinnedScrollPosition() {
    var transaction = Transaction()
    transaction.animation = nil
    withTransaction(transaction) {
      scrollPositionID = Self.bottomSentinelID
    }
  }

  private func isUserDrivenScrollPhase(_ phase: ScrollPhase) -> Bool {
    switch phase {
      case .tracking, .interacting, .decelerating:
        true
      case .idle, .animating:
        false
    }
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

  private var isUndone: Bool {
    entry.turnStatus == .undone || entry.turnStatus == .rolledBack
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
    .opacity(isUndone ? OpacityTier.strong : 1.0)
    .overlay(alignment: .topTrailing) {
      if isUndone {
        UndoneRowBadge(status: entry.turnStatus)
      }
    }
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

private struct UndoneRowBadge: View {
  let status: TurnStatus

  private var label: String {
    status == .undone ? "Undone" : "Rolled back"
  }

  var body: some View {
    Text(label)
      .font(.caption2)
      .fontWeight(.medium)
      .foregroundStyle(Color.textTertiary)
      .padding(.horizontal, Spacing.sm_)
      .padding(.vertical, Spacing.xxs)
      .background(Color.backgroundTertiary, in: Capsule())
      .padding(.trailing, Spacing.lg)
      .padding(.top, Spacing.xs)
  }
}
