import Foundation
@testable import OrbitDock
import Testing

struct ConversationViewStateTests {
  @Test func deriveShowsLoadingWhileBootstrapIsInFlight() {
    let state = ConversationViewState.derive(
      messageCount: 0,
      totalMessageCount: 0,
      hasRenderableConversation: false,
      hydrationState: .loadingRecent,
      hasMoreHistoryBefore: false,
      pageSize: 50
    )

    #expect(state.loadState == .loading)
    #expect(!state.hasMoreMessages)
    #expect(state.remainingLoadCount == 0)
    #expect(state.totalMessageCount == 0)
  }

  @Test func deriveShowsReadyWhenRenderableConversationExists() {
    let state = ConversationViewState.derive(
      messageCount: 24,
      totalMessageCount: 40,
      hasRenderableConversation: true,
      hydrationState: .readyPartial,
      hasMoreHistoryBefore: true,
      pageSize: 50
    )

    #expect(state.loadState == .ready)
    #expect(state.hasMoreMessages)
    #expect(state.remainingLoadCount == 16)
    #expect(state.totalMessageCount == 40)
  }

  @Test func deriveShowsEmptyWhenBootstrapFinishedWithoutRenderableContent() {
    let state = ConversationViewState.derive(
      messageCount: 0,
      totalMessageCount: 0,
      hasRenderableConversation: false,
      hydrationState: .failed,
      hasMoreHistoryBefore: false,
      pageSize: 50
    )

    #expect(state.loadState == .empty)
  }

  @Test func deriveCapsRemainingLoadCountToPageSize() {
    let state = ConversationViewState.derive(
      messageCount: 30,
      totalMessageCount: 200,
      hasRenderableConversation: true,
      hydrationState: .readyPartial,
      hasMoreHistoryBefore: true,
      pageSize: 50
    )

    #expect(state.remainingLoadCount == 50)
  }

  @Test func deriveNeverUndercountsVisibleMessages() {
    let state = ConversationViewState.derive(
      messageCount: 18,
      totalMessageCount: 4,
      hasRenderableConversation: true,
      hydrationState: .readyComplete,
      hasMoreHistoryBefore: false,
      pageSize: 50
    )

    #expect(state.totalMessageCount == 18)
    #expect(state.remainingLoadCount == 0)
  }
}
