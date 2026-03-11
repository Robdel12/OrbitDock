import Testing
@testable import OrbitDock

struct SessionSnapshotRefreshPolicyTests {
  @Test func refreshesWhenSubscribedSessionHasActiveSubagents() {
    let shouldRefresh = SessionStore.shouldRefreshSnapshotForAppendedMessage(
      isSubscribed: true,
      subagentStatuses: [.completed, .pending]
    )

    #expect(shouldRefresh)
  }

  @Test func skipsRefreshWhenNoActiveSubagentsOrSessionIsNotSubscribed() {
    #expect(
      !SessionStore.shouldRefreshSnapshotForAppendedMessage(
        isSubscribed: false,
        subagentStatuses: [.pending]
      )
    )
    #expect(
      !SessionStore.shouldRefreshSnapshotForAppendedMessage(
        isSubscribed: true,
        subagentStatuses: [.completed, .failed, nil]
      )
    )
  }
}
