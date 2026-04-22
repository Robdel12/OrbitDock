//
//  TimelineScrollView.swift
//  OrbitDock
//
//  Pure SwiftUI replacement for NSTableView/UICollectionView timeline.
//  Heights are automatic — no manual measurement or caching needed.
//
//  Follow (pin-to-bottom) logic:
//  - Timeline scroll/follow state is owned locally via ConversationTimelineScrollState
//    so the scroll position binding only reads same-view state — no cross-frame
//    race with parent props.
//  - When pinned, the bound position stays on the bottom sentinel so container
//    height and content height changes preserve bottom alignment declaratively.
//  - User-driven scrolling is detected by bridging the underlying platform
//    scroll view so content/layout changes do not masquerade as user intent.
//  - The parent is notified of follow state changes via onFollowStateChanged
//    and sends commands (jump to latest, toggle, reveal) via scrollCommand.
//

import SwiftUI

struct TimelineScrollView: View {
  let viewModel: ConversationTimelineViewModel
  let sessionId: String
  let endpointId: UUID?
  let clients: ServerClients
  @Binding var scrollCommand: ConversationScrollCommand?
  let onLoadMore: (() -> Void)?
  let latestAppendEvent: ConversationLatestAppendEvent?
  let onFollowStateChanged: (ConversationFollowState) -> Void

  private static let bottomSentinelID = "timeline-bottom"
  private static let bottomAnchorHeight: CGFloat = 20
  private static let topThreshold: CGFloat = 36
  private static let bottomThreshold: CGFloat = 36
  private static let defaultRecentRenderWindow = 60

  @Environment(\.horizontalSizeClass) private var sizeClass

  @State private var scrollState = ConversationTimelineScrollState(
    bottomSentinelID: Self.bottomSentinelID,
    recentRenderWindow: Self.defaultRecentRenderWindow
  )

  private var recentRenderWindow: Int {
    sizeClass == .compact ? 40 : 60
  }

  private var historyRenderExpansionStep: Int {
    sizeClass == .compact ? 20 : 40
  }

  var body: some View {
    let displayedCount = viewModel.displayedEntryCount
    let rendered = viewModel.renderedEntries(limit: scrollState.renderedEntryLimit)
    let hiddenRenderedCount = max(displayedCount - rendered.count, 0)

    ScrollViewReader { proxy in
      ScrollView(.vertical) {
        // Conversation rows mutate height constantly while streaming, expanding,
        // loading media, and prepending history. In practice the lazy stack was
        // evicting the visible subtree during those layout shifts, which left
        // the viewport blank until the user scrolled again. A plain VStack keeps
        // realized rows alive and trades a bit of memory for much more stable
        // rendering behavior.
        VStack(spacing: 0) {
          // Pagination sentinel — triggers history load when scrolled into view.
          // Identity changes when older messages prepend (first entry's sequence
          // changes), so onAppear fires again for the next page.
          Color.clear
            .frame(height: 1)
            .id("pagination-\(rendered.first?.sequence ?? 0)")
            .onAppear {
              guard scrollState.isNearTop else { return }
              requestLoadMoreIfNeeded(
                totalCount: displayedCount,
                hiddenRenderedCount: hiddenRenderedCount,
                firstRenderedAnchorID: rendered.first?.id,
                with: proxy
              )
            }

          ForEach(rendered) { entry in
            TimelineRowHost(
              entry: entry,
              sessionId: sessionId,
              endpointId: endpointId,
              clients: clients,
              viewModel: viewModel
            )
            .id(entry.id)
          }

          // Bottom sentinel — padded docking region used only as the follow target.
          Color.clear
            .frame(height: Self.bottomAnchorHeight)
            .id(Self.bottomSentinelID)
        }
        .scrollTargetLayout()
        .background {
          TimelineUserScrollDetector(
            isUserScrolling: detectorBinding(\.isUserScrolling),
            isNearTop: detectorBinding(\.isNearTop),
            isNearBottom: detectorBinding(\.isNearBottom),
            topThreshold: Self.topThreshold,
            bottomThreshold: Self.bottomThreshold
          )
          .frame(width: 0, height: 0)
        }
      }
      .scrollDismissesKeyboard(.interactively)
      .defaultScrollAnchor(.bottom)
      .scrollPosition(id: scrollPositionBinding, anchor: .bottom)
      .background(Color.backgroundPrimary)
      .task {
        guard !scrollState.hasInitializedScrollPosition else { return }
        scrollState.hasInitializedScrollPosition = true
        scrollState.renderedEntryLimit = recentRenderWindow
        if scrollState.followState.mode.isFollowing {
          scrollState.syncRenderedEntryLimit(totalCount: displayedCount, recentWindow: recentRenderWindow)
          setPinnedScrollPosition()
        }
        if scrollState.pendingNearTopLoad || scrollState.isNearTop {
          requestLoadMoreIfNeeded(
            totalCount: displayedCount,
            hiddenRenderedCount: hiddenRenderedCount,
            firstRenderedAnchorID: rendered.first?.id,
            with: proxy
          )
        }
      }
      .onChange(of: displayedCount) { oldCount, newCount in
        let countDelta = newCount - oldCount
        guard countDelta != 0 else {
          scrollState.renderedEntryLimit = min(scrollState.renderedEntryLimit, newCount)
          return
        }

        if scrollState.pendingHistoryReveal, countDelta > 0, !scrollState.followState.mode.isFollowing {
          scrollState.pendingHistoryReveal = false
          scrollState.renderedEntryLimit = min(newCount, scrollState.renderedEntryLimit + countDelta)
          return
        }

        if scrollState.followState.mode.isFollowing {
          if countDelta > 0 {
            scrollState.renderedEntryLimit = ConversationRenderWindowPlanner.followingAppendLimit(
              currentLimit: scrollState.renderedEntryLimit,
              totalCount: newCount,
              recentWindow: recentRenderWindow
            )
            setPinnedScrollPosition()
          } else {
            scrollState.syncRenderedEntryLimit(totalCount: newCount, recentWindow: recentRenderWindow)
          }
          return
        }

        if countDelta > 0 {
          scrollState.renderedEntryLimit = min(newCount, scrollState.renderedEntryLimit + countDelta)
        } else {
          scrollState.renderedEntryLimit = min(scrollState.renderedEntryLimit, newCount)
        }
      }
      .onChange(of: sizeClass) { _, _ in
        scrollState.syncRenderedEntryLimit(totalCount: displayedCount, recentWindow: recentRenderWindow)
      }
      .onChange(of: scrollState.isNearTop) { _, isVisible in
        guard isVisible else { return }
        requestLoadMoreIfNeeded(
          totalCount: displayedCount,
          hiddenRenderedCount: hiddenRenderedCount,
          firstRenderedAnchorID: rendered.first?.id,
          with: proxy
        )
      }
      .onChange(of: scrollState.isNearBottom) { _, isVisible in
        if isVisible, !scrollState.followState.mode.isFollowing {
          applyIntent(.viewportEvent(.reachedBottom))
          return
        }

        guard !isVisible, scrollState.followState.mode.isFollowing, scrollState.isUserScrolling else { return }
        guard !scrollState.hasDetachedFromBottomDuringCurrentGesture else { return }
        scrollState.hasDetachedFromBottomDuringCurrentGesture = true
        applyIntent(.viewportEvent(.leftBottomByUser))
      }
      .onChange(of: scrollState.isUserScrolling) { _, scrolling in
        if scrolling {
          scrollState.hasDetachedFromBottomDuringCurrentGesture = false
          return
        }

        guard !scrollState.hasDetachedFromBottomDuringCurrentGesture else { return }
        guard scrollState.followState.mode.isFollowing, !scrollState.isNearBottom else { return }
        scrollState.hasDetachedFromBottomDuringCurrentGesture = true
        applyIntent(.viewportEvent(.leftBottomByUser))
      }
      .onChange(of: latestAppendEvent) { _, event in
        guard let event else { return }
        if let requiredVisibleSuffixCount = event.requiredVisibleSuffixCount,
           requiredVisibleSuffixCount > scrollState.renderedEntryLimit
        {
          var transaction = Transaction()
          transaction.animation = nil
          withTransaction(transaction) {
            scrollState.renderedEntryLimit = min(viewModel.displayedEntryCount, requiredVisibleSuffixCount)
          }
          if scrollState.followState.mode.isFollowing {
            setPinnedScrollPosition()
          }
        }

        guard event.count > 0 else { return }
        guard !scrollState.followState.mode.isFollowing else { return }
        applyIntent(.latestEntriesAppended(event.count))
      }
      .onChange(of: scrollCommand) { _, command in
        guard let command else { return }
        run(command: command, with: proxy)
      }
    }
  }

  // MARK: - Follow Intent Processing

  private func applyIntent(_ intent: ConversationFollowIntent) {
    let plan = ConversationFollowPlanner.apply(current: scrollState.followState, intent: intent)
    guard plan.state != scrollState.followState || plan.scrollAction != nil else { return }
    scrollState.apply(
      plan.state,
      totalCount: viewModel.displayedEntryCount,
      recentWindow: recentRenderWindow
    )
    onFollowStateChanged(plan.state)

    guard let action = plan.scrollAction else { return }
    switch action {
      case .latest:
        setPinnedScrollPosition()
      case .message:
        // Message scrolling requires ScrollViewProxy — handled via scrollCommand path
        break
    }
  }

  // MARK: - Scroll Actions

  private func setPinnedScrollPosition() {
    var transaction = Transaction()
    transaction.animation = nil
    withTransaction(transaction) {
      scrollState.setPinnedScrollPosition()
    }
  }

  private func scrollToMessage(_ messageID: String, with proxy: ScrollViewProxy) {
    let anchorID = viewModel.displayAnchorID(for: messageID) ?? messageID
    let requiredLimit = viewModel.renderWindowRequiredToReveal(rowId: messageID) ?? scrollState.renderedEntryLimit
    let shouldExpandWindow = requiredLimit > scrollState.renderedEntryLimit

    if shouldExpandWindow {
      var expansionTransaction = Transaction()
      expansionTransaction.animation = nil
      withTransaction(expansionTransaction) {
        scrollState.renderedEntryLimit = min(viewModel.displayedEntryCount, requiredLimit)
      }
    }

    let performScroll = {
      var transaction = Transaction()
      transaction.animation = Motion.standard
      withTransaction(transaction) {
        proxy.scrollTo(anchorID, anchor: .center)
      }
    }

    if shouldExpandWindow {
      Task { @MainActor in
        await Task.yield()
        performScroll()
      }
      return
    }

    var transaction = Transaction()
    transaction.animation = Motion.standard
    withTransaction(transaction) {
      proxy.scrollTo(anchorID, anchor: .center)
    }
  }

  private func run(command: ConversationScrollCommand, with proxy: ScrollViewProxy) {
    switch command {
      case .latest:
        scrollState.followState = .initial
        scrollState.syncRenderedEntryLimit(
          totalCount: viewModel.displayedEntryCount,
          recentWindow: recentRenderWindow
        )
        setPinnedScrollPosition()
      case let .message(id, _):
        scrollToMessage(id, with: proxy)
      case .jumpToLatest:
        applyIntent(.jumpToLatest)
      case let .revealMessage(id, _):
        applyIntent(.revealMessage(id))
        scrollToMessage(id, with: proxy)
      case .toggleFollow:
        applyIntent(.toggleFollow)
      case .openPendingApproval:
        applyIntent(.openPendingApprovalPanel)
    }
  }

  // MARK: - Scroll Position Binding

  private var scrollPositionBinding: Binding<String?> {
    Binding(
      get: {
        // All reads are local @State — no cross-frame race with parent props.
        // When following: return the commanded position (bottom sentinel) to
        // pin the viewport to the bottom.
        // When detached: return nil so .scrollPosition does not fight the
        // user's scroll offset. Without this, the .bottom anchor tries to
        // reposition the viewport every layout pass (e.g. when new content
        // arrives), causing visible jank.
        scrollState.scrollPositionID
      },
      set: { newValue in
        scrollState.observedScrollPositionID = newValue
      }
    )
  }

  private func revealOlderRenderedEntries(
    totalCount: Int,
    anchorID: String?,
    with proxy: ScrollViewProxy
  ) {
    guard totalCount > scrollState.renderedEntryLimit else { return }
    let nextLimit = min(totalCount, scrollState.renderedEntryLimit + historyRenderExpansionStep)
    guard nextLimit != scrollState.renderedEntryLimit else { return }

    var transaction = Transaction()
    transaction.animation = nil
    withTransaction(transaction) {
      scrollState.renderedEntryLimit = nextLimit
    }

    if let anchorID {
      withTransaction(transaction) {
        proxy.scrollTo(anchorID, anchor: .top)
      }
    }
  }

  private func loadMoreIfNeeded(
    totalCount: Int,
    hiddenRenderedCount: Int,
    firstRenderedAnchorID: String?,
    with proxy: ScrollViewProxy
  ) {
    if hiddenRenderedCount > 0 {
      revealOlderRenderedEntries(
        totalCount: totalCount,
        anchorID: firstRenderedAnchorID,
        with: proxy
      )
      return
    }

    scrollState.pendingHistoryReveal = true
    onLoadMore?()
  }

  private func requestLoadMoreIfNeeded(
    totalCount: Int,
    hiddenRenderedCount: Int,
    firstRenderedAnchorID: String?,
    with proxy: ScrollViewProxy
  ) {
    guard !scrollState.followState.mode.isFollowing else { return }
    guard scrollState.hasInitializedScrollPosition else {
      scrollState.pendingNearTopLoad = true
      return
    }

    scrollState.pendingNearTopLoad = false
    loadMoreIfNeeded(
      totalCount: totalCount,
      hiddenRenderedCount: hiddenRenderedCount,
      firstRenderedAnchorID: firstRenderedAnchorID,
      with: proxy
    )
  }

  private func detectorBinding<Value>(_ keyPath: WritableKeyPath<ConversationTimelineScrollState, Value>) -> Binding<Value> {
    Binding(
      get: { scrollState[keyPath: keyPath] },
      set: { scrollState[keyPath: keyPath] = $0 }
    )
  }

}

private struct TimelineRowHost: View {
  let entry: ServerConversationRowEntry
  let sessionId: String
  let endpointId: UUID?
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
      endpointId: endpointId,
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
