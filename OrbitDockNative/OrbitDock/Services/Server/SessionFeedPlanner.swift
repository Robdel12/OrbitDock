import Foundation

enum SessionFeedBootstrapStrategy: Equatable {
  case retainedSnapshot
  case cachedSnapshot
  case freshBootstrap
}

struct SessionFeedSubscriptionPlan: Equatable {
  let strategy: SessionFeedBootstrapStrategy
  let deferredBootstrapGoal: ConversationRecoveryGoal?
  let shouldFetchApprovals: Bool
}

struct SessionReplayRequest: Equatable {
  let sessionId: String
  let sinceRevision: UInt64?
  let includeSnapshot: Bool
}

struct SessionConnectionRecoveryPlan: Equatable {
  let shouldResetInitialSessionsList: Bool
  let shouldSubscribeList: Bool
  let replayRequests: [SessionReplayRequest]
}

enum SessionFeedPlanner {
  static func subscriptionPlan(
    forceRefresh: Bool,
    hasInitialConversationData: Bool,
    hasCachedConversation: Bool,
    recoveryGoal: ConversationRecoveryGoal
  ) -> SessionFeedSubscriptionPlan {
    if !forceRefresh, hasInitialConversationData {
      return SessionFeedSubscriptionPlan(
        strategy: .retainedSnapshot,
        deferredBootstrapGoal: recoveryGoal == .completeHistory ? recoveryGoal : nil,
        shouldFetchApprovals: true
      )
    }

    if !forceRefresh, hasCachedConversation {
      return SessionFeedSubscriptionPlan(
        strategy: .cachedSnapshot,
        deferredBootstrapGoal: recoveryGoal,
        shouldFetchApprovals: true
      )
    }

    return SessionFeedSubscriptionPlan(
      strategy: .freshBootstrap,
      deferredBootstrapGoal: nil,
      shouldFetchApprovals: true
    )
  }

  static func connectionRecoveryPlan(
    status: ConnectionStatus,
    subscribedSessionIds: Set<String>,
    sessionHasInitialConversationData: [String: Bool],
    lastRevisionBySession: [String: UInt64]
  ) -> SessionConnectionRecoveryPlan? {
    switch status {
      case .connected:
        let replayRequests = subscribedSessionIds
          .sorted()
          .map { sessionId in
            SessionReplayRequest(
              sessionId: sessionId,
              sinceRevision: lastRevisionBySession[sessionId],
              includeSnapshot: !(sessionHasInitialConversationData[sessionId] ?? false)
            )
          }

        return SessionConnectionRecoveryPlan(
          shouldResetInitialSessionsList: true,
          shouldSubscribeList: true,
          replayRequests: replayRequests
        )

      case .disconnected:
        return SessionConnectionRecoveryPlan(
          shouldResetInitialSessionsList: true,
          shouldSubscribeList: false,
          replayRequests: []
        )

      case .connecting, .failed:
        return nil
    }
  }
}
