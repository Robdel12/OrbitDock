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

  @Test func applyFollowStateStoresLatestTimelineState() {
    let viewModel = ConversationViewModel()
    let followState = ConversationFollowState(mode: .programmaticNavigation, unreadCount: 2)

    viewModel.applyFollowState(followState)

    #expect(viewModel.followState == followState)
  }
}
