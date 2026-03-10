import Foundation
import Testing
@testable import OrbitDock

struct SessionFeedPlannerTests {
  @Test func retainedSnapshotPlanOnlyBackfillsForCompleteHistory() {
    let recentPlan = SessionFeedPlanner.subscriptionPlan(
      forceRefresh: false,
      hasInitialConversationData: true,
      hasCachedConversation: true,
      recoveryGoal: .coherentRecent
    )

    #expect(recentPlan.strategy == .retainedSnapshot)
    #expect(recentPlan.deferredBootstrapGoal == nil)
    #expect(recentPlan.shouldFetchApprovals)

    let fullPlan = SessionFeedPlanner.subscriptionPlan(
      forceRefresh: false,
      hasInitialConversationData: true,
      hasCachedConversation: true,
      recoveryGoal: .completeHistory
    )

    #expect(fullPlan.strategy == .retainedSnapshot)
    #expect(fullPlan.deferredBootstrapGoal == .completeHistory)
  }

  @Test func cachedSnapshotPlanRestoresThenReconciles() {
    let plan = SessionFeedPlanner.subscriptionPlan(
      forceRefresh: false,
      hasInitialConversationData: false,
      hasCachedConversation: true,
      recoveryGoal: .coherentRecent
    )

    #expect(plan.strategy == .cachedSnapshot)
    #expect(plan.deferredBootstrapGoal == .coherentRecent)
    #expect(plan.shouldFetchApprovals)
  }

  @Test func freshBootstrapPlanWinsWhenForcedOrCold() {
    let forcedPlan = SessionFeedPlanner.subscriptionPlan(
      forceRefresh: true,
      hasInitialConversationData: true,
      hasCachedConversation: true,
      recoveryGoal: .completeHistory
    )
    #expect(forcedPlan.strategy == .freshBootstrap)
    #expect(forcedPlan.deferredBootstrapGoal == nil)

    let coldPlan = SessionFeedPlanner.subscriptionPlan(
      forceRefresh: false,
      hasInitialConversationData: false,
      hasCachedConversation: false,
      recoveryGoal: .coherentRecent
    )
    #expect(coldPlan.strategy == .freshBootstrap)
    #expect(coldPlan.deferredBootstrapGoal == nil)
  }

  @Test func connectedRecoveryPlanBuildsStableReplayRequests() {
    let plan = SessionFeedPlanner.connectionRecoveryPlan(
      status: .connected,
      subscribedSessionIds: ["session-b", "session-a"],
      sessionHasInitialConversationData: [
        "session-a": true,
        "session-b": false,
      ],
      lastRevisionBySession: [
        "session-a": 9,
      ]
    )

    #expect(plan?.shouldResetInitialSessionsList == true)
    #expect(plan?.shouldSubscribeList == true)
    #expect(plan?.replayRequests == [
      SessionReplayRequest(sessionId: "session-a", sinceRevision: 9, includeSnapshot: false),
      SessionReplayRequest(sessionId: "session-b", sinceRevision: nil, includeSnapshot: true),
    ])
  }

  @Test func disconnectedRecoveryPlanOnlyResetsInitialList() {
    let plan = SessionFeedPlanner.connectionRecoveryPlan(
      status: .disconnected,
      subscribedSessionIds: ["session-a"],
      sessionHasInitialConversationData: ["session-a": true],
      lastRevisionBySession: ["session-a": 42]
    )

    #expect(plan?.shouldResetInitialSessionsList == true)
    #expect(plan?.shouldSubscribeList == false)
    #expect(plan?.replayRequests.isEmpty == true)
  }

  @Test func connectingAndFailedStatusesDoNotProduceRecoveryWork() {
    #expect(
      SessionFeedPlanner.connectionRecoveryPlan(
        status: .connecting,
        subscribedSessionIds: [],
        sessionHasInitialConversationData: [:],
        lastRevisionBySession: [:]
      ) == nil
    )

    #expect(
      SessionFeedPlanner.connectionRecoveryPlan(
        status: .failed("offline"),
        subscribedSessionIds: ["session-a"],
        sessionHasInitialConversationData: [:],
        lastRevisionBySession: [:]
      ) == nil
    )
  }
}
