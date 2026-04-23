@testable import OrbitDock
import Testing

@MainActor
struct ConversationViewModelTests {
  @Test func bindingNewSessionClearsFollowState() {
    let session = ServerSessionContext.preview()
    let viewModel = ConversationViewModel(
      sessionId: "session-1",
      session: session,
      viewMode: .focused
    )

    viewModel.applyFollowState(
      ConversationFollowState(mode: .detachedByUser, unreadCount: 4)
    )

    viewModel.bind(
      sessionId: "session-2",
      session: ServerSessionContext.preview(),
      viewMode: .focused
    )

    #expect(viewModel.followState == .initial)
  }

  @Test func bindingNewSessionShowsLoadingEvenAfterPreviousContent() {
    let viewModel = ConversationViewModel(
      sessionId: "session-1",
      session: ServerSessionContext.preview(),
      viewMode: .focused
    )

    viewModel.handleLoadStateChange(.ready)
    viewModel.bind(
      sessionId: "session-2",
      session: ServerSessionContext.preview(),
      viewMode: .focused
    )

    #expect(!viewModel.hasShownContent)
    #expect(viewModel.loadState == .loading)
  }

  @Test func applyFollowStateStoresLatestTimelineState() {
    let viewModel = ConversationViewModel()
    let followState = ConversationFollowState(mode: .programmaticNavigation, unreadCount: 2)

    viewModel.applyFollowState(followState)

    #expect(viewModel.followState == followState)
  }

  @Test func agentThreadPagesPopulateNormalConversationTimeline() {
    let session = ServerSessionContext.preview()
    let viewModel = ConversationViewModel(
      sessionId: "parent-session",
      session: session,
      viewMode: .focused
    )

    viewModel.bind(
      sessionId: "parent-session",
      session: session,
      viewMode: .focused,
      routeKey: "parent-session:agent-thread:thread-1",
      agentThreadId: "thread-1"
    )

    viewModel.applyAgentThreadPage(
      makeAgentThreadPage(
        rows: [
          makeRow(id: "assistant-2", sequence: 2, content: "I found the coordinator."),
          makeRow(id: "assistant-4", sequence: 4, content: "The patch is ready."),
        ],
        totalRowCount: 4,
        hasMoreBefore: true
      )
    )

    #expect(viewModel.loadState == .ready)
    #expect(viewModel.hasTimeline)
    #expect(viewModel.rowEntries.map(\.sequence) == [2, 4])
    #expect(viewModel.currentAgentThreadId == "thread-1")

    let mergedOlderPage = ConversationHistoryPaging.mergeOlderPage(
      existingRows: viewModel.rowEntries,
      page: makeAgentThreadPage(
        rows: [
          makeRow(id: "user-1", sequence: 1, content: "Please inspect auth."),
          makeRow(id: "assistant-2", sequence: 2, content: "I found the coordinator."),
        ],
        totalRowCount: 4,
        hasMoreBefore: false
      )
    )

    #expect(mergedOlderPage.rows.map(\.sequence) == [1, 2, 4])
    #expect(!mergedOlderPage.hasMoreBefore)
    #expect(mergedOlderPage.totalRowCount == 4)
  }

  private func makeAgentThreadPage(
    rows: [ServerConversationRowEntry],
    totalRowCount: UInt64,
    hasMoreBefore: Bool
  ) -> ServerAgentThreadConversationPage {
    ServerAgentThreadConversationPage(
      sessionId: "parent-session",
      threadId: "thread-1",
      rows: rows,
      totalRowCount: totalRowCount,
      hasMoreBefore: hasMoreBefore,
      oldestSequence: rows.first?.sequence,
      newestSequence: rows.last?.sequence,
      freshness: .pollable
    )
  }

  private func makeRow(id: String, sequence: UInt64, content: String) -> ServerConversationRowEntry {
    ServerConversationRowEntry(
      sessionId: "thread-1",
      sequence: sequence,
      turnId: nil,
      row: .assistant(ServerConversationMessageRow(id: id, content: content))
    )
  }
}
